package main

import (
	"sync"
	"testing"

	"hotkeyd/internal/x11"
)

// fakeDeviceQuerier is an XIQueryDevice double: it records every call and
// answers from a static id->name table, so a miss can be told apart from a
// device that is merely absent right now.
type fakeDeviceQuerier struct {
	mu      sync.Mutex
	byID    map[uint16]string
	queries []uint16
}

func newFakeDeviceQuerier(byID map[uint16]string) *fakeDeviceQuerier {
	return &fakeDeviceQuerier{byID: byID}
}

func (f *fakeDeviceQuerier) query(deviceid uint16) ([]x11.XIDeviceInfo, error) {
	f.mu.Lock()
	f.queries = append(f.queries, deviceid)
	f.mu.Unlock()

	name, ok := f.byID[deviceid]
	if !ok {
		return nil, nil // XIQueryDevice(unknown id) -- empty, not an error
	}
	return []x11.XIDeviceInfo{{DeviceID: deviceid, Name: name}}, nil
}

func (f *fakeDeviceQuerier) queryCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.queries)
}

func TestDeviceRegistry_Name_ResolvesAndCaches(t *testing.T) {
	fq := newFakeDeviceQuerier(map[uint16]string{12: "AT Translated Set 2 keyboard"})
	r := NewDeviceRegistry(fq.query)

	name, ok := r.Name(12)
	if !ok || name != "AT Translated Set 2 keyboard" {
		t.Fatalf("Name(12) = %q, %v, want %q, true", name, ok, "AT Translated Set 2 keyboard")
	}

	// Second lookup must be served from cache, not a second query.
	r.Name(12)
	if got := fq.queryCount(); got != 1 {
		t.Fatalf("query count = %d, want 1 (second Name() call should hit cache)", got)
	}
}

func TestDeviceRegistry_Name_MissIsNeverCached(t *testing.T) {
	fq := newFakeDeviceQuerier(map[uint16]string{}) // 99 unknown
	r := NewDeviceRegistry(fq.query)

	if _, ok := r.Name(99); ok {
		t.Fatal("Name(99) ok = true, want false for an unknown device")
	}
	if _, ok := r.Name(99); ok {
		t.Fatal("Name(99) ok = true on second call, want false")
	}
	if got := fq.queryCount(); got != 2 {
		t.Fatalf("query count = %d, want 2 -- a miss must never be cached (the device may exist after the next hierarchy change)", got)
	}
}

func TestDeviceRegistry_Invalidate_ClearsCache(t *testing.T) {
	fq := newFakeDeviceQuerier(map[uint16]string{12: "BlueZ 5.86 (MCS)"})
	r := NewDeviceRegistry(fq.query)

	r.Name(12)
	r.Invalidate()
	r.Name(12)

	if got := fq.queryCount(); got != 2 {
		t.Fatalf("query count = %d, want 2 -- Invalidate must force a fresh query", got)
	}
}

func TestDeviceRegistry_Invalidate_StaleNameNeverSurvivesIDReuse(t *testing.T) {
	// A bluetooth keyboard powers off and its id is reused by a different
	// physical device. Without invalidation, the old name would attribute
	// the new device's keys to the wrong keyboard.
	fq := newFakeDeviceQuerier(map[uint16]string{12: "BlueZ 5.86 (MCS)"})
	r := NewDeviceRegistry(fq.query)
	r.Name(12) // cached as "BlueZ 5.86 (MCS)"

	fq.byID[12] = "Acer WMI hotkeys" // id 12 reassigned
	r.Invalidate()

	name, ok := r.Name(12)
	if !ok || name != "Acer WMI hotkeys" {
		t.Fatalf("Name(12) after Invalidate = %q, %v, want %q, true", name, ok, "Acer WMI hotkeys")
	}
}

func TestAttributeSource_ReadsSourceIDNotDeviceID(t *testing.T) {
	// ft011's measured failure: reading the event header's DeviceID (the
	// master) instead of SourceID (the physical slave) reports every
	// keyboard on a display as "Virtual core keyboard". deviceid=3 here is
	// deliberately named as the master to prove AttributeSource does not
	// read it.
	fq := newFakeDeviceQuerier(map[uint16]string{
		3:  "Virtual core keyboard",
		12: "AT Translated Set 2 keyboard",
	})
	r := NewDeviceRegistry(fq.query)

	ev := x11.DeviceEvent{DeviceID: 3, SourceID: 12}
	name, ok := r.AttributeSource(ev)

	if !ok || name != "AT Translated Set 2 keyboard" {
		t.Fatalf("AttributeSource(ev) = %q, %v, want %q, true (the SOURCE, not %q the master)",
			name, ok, "AT Translated Set 2 keyboard", "Virtual core keyboard")
	}
}

func TestDeviceRegistry_ConcurrentInvalidateAndName_NoDataRace(t *testing.T) {
	// Edge case from the task design: a hierarchy event mid-dispatch must
	// not corrupt an in-flight event's attribution. Run under `go test
	// -race`: a missing lock here is a real data race, not just a logic
	// bug, since Invalidate and Name can run from different goroutines
	// (the read loop dispatching an event vs. a hierarchy-change handler).
	fq := newFakeDeviceQuerier(map[uint16]string{12: "AT Translated Set 2 keyboard"})
	r := NewDeviceRegistry(fq.query)

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func(id uint16) {
			defer wg.Done()
			r.Name(id)
		}(uint16(12 + i%3))
		go func() {
			defer wg.Done()
			r.Invalidate()
		}()
	}
	wg.Wait()
}
