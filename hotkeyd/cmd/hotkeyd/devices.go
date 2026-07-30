package main

import (
	"sync"

	"hotkeyd/internal/x11"
)

// deviceQuerier matches x11.Conn.XIQueryDevice's shape -- the seam that
// lets DeviceRegistry run against a fake XI2 server in tests. Production
// wiring is `conn.XIQueryDevice` partially applied to the connection's
// learned XInputExtension major opcode.
type deviceQuerier func(deviceid uint16) ([]x11.XIDeviceInfo, error)

// DeviceRegistry caches XI2 device id -> name for the process lifetime,
// invalidated wholesale on an XI2 hierarchy or device-changed event. Ported
// from hotkeyd.py's DeviceRegistry ([[ft011]]).
//
// Resolution must be by SOURCE id, never the master in an event header: XI2
// puts the master keyboard in DeviceEvent.DeviceID and the physical slave
// that actually produced the event in DeviceEvent.SourceID -- reading the
// header would report every keyboard on a display as "Virtual core
// keyboard" (measured). AttributeSource exists so that mistake has exactly
// one place it could be made, and this is not it.
//
// The cache is dropped wholesale by Invalidate on a hierarchy change: ids
// are reused by the server (a bluetooth keyboard powering off, a device
// plugged in after startup), so a stale name would attribute one
// keyboard's keys to another. A lookup that FAILS is never cached: the
// device may exist after the next hierarchy change, and caching the miss
// would keep it nameless forever.
//
// Safe for concurrent use: Invalidate can run from a hierarchy-event
// handler while Name runs from the event-dispatch path, and the mutex
// guarantees an in-flight Name call observes either the pre- or the
// post-invalidation cache atomically, never a torn one.
type DeviceRegistry struct {
	query deviceQuerier

	mu    sync.Mutex
	names map[uint16]string
}

// NewDeviceRegistry builds a DeviceRegistry that resolves cache misses via
// query.
func NewDeviceRegistry(query deviceQuerier) *DeviceRegistry {
	return &DeviceRegistry{query: query, names: map[uint16]string{}}
}

// Invalidate drops the entire name cache.
func (r *DeviceRegistry) Invalidate() {
	r.mu.Lock()
	r.names = map[uint16]string{}
	r.mu.Unlock()
}

// Name resolves deviceid to its device name, querying XIQueryDevice on a
// cache miss. Returns ("", false) when the device is unknown or the query
// fails -- and does NOT cache that outcome, so the device can resolve once
// it (re)appears.
func (r *DeviceRegistry) Name(deviceid uint16) (string, bool) {
	r.mu.Lock()
	if name, ok := r.names[deviceid]; ok {
		r.mu.Unlock()
		return name, true
	}
	r.mu.Unlock()

	infos, err := r.query(deviceid)
	if err != nil {
		return "", false
	}
	for _, info := range infos {
		if info.DeviceID == deviceid {
			r.mu.Lock()
			r.names[deviceid] = info.Name
			r.mu.Unlock()
			return info.Name, true
		}
	}
	return "", false
}

// AttributeSource resolves the physical device that produced ev, reading
// ev.SourceID -- the slave -- and never ev.DeviceID -- the master. See the
// DeviceRegistry doc for why reading the header's DeviceID here would be
// wrong.
func (r *DeviceRegistry) AttributeSource(ev x11.DeviceEvent) (name string, ok bool) {
	return r.Name(ev.SourceID)
}
