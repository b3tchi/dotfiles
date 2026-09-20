// thread.go derives conversation threads from a flat []source.Message
// (sp034 Task 1). It is a pure, stateless function -- no map, no clock, no
// tui.Model -- matching subject.go's own shape (## plan). Threading is a
// reader-side display derivation over what ft014's messages verb already
// publishes: no thread_id is written onto an envelope (adr0028), and
// nothing here parses content (adr0031).
//
// Keying is on the envelope's own ADDRESSES, never on the rendered From/To
// labels (adr0034): a label two parties share is exactly what resolution
// refuses to answer, so keying on labels would collapse two different
// conversations into one thread. The key is the sorted, de-duplicated
// union of FromAddress and ToAddresses, joined with "|" -- a separator that
// cannot appear inside a pi-worker address (addressPattern in log.go is
// base32 Crockford).
package render

import (
	"sort"
	"strings"

	"agent-monitor/internal/source"
)

// threadKeySep joins a thread's sorted address set.
const threadKeySep = "|"

// Thread groups the envelopes that share one participant-address set.
type Thread struct {
	// Key is join(sort(dedupe({FromAddress} u ToAddresses)), "|") -- the
	// same for every message in Messages.
	Key string
	// Messages are this thread's own envelopes, newest-first, matching the
	// pane's own order (sp033 T6).
	Messages []source.Message
	// Count is len(Messages).
	Count int
	// Participants are display labels, one per address in Key's sorted
	// set (same order), resolved from the thread's own envelopes by
	// pairing FromAddress/From and ToAddresses[i]/To[i] positionally --
	// falling back to shortAddress of the raw address when no message in
	// the thread supplies a trustworthy label for it.
	Participants []string
}

// isNewer reports whether a is newer than b: by At, with ties (equal At)
// resolved by ID descending. This one rule orders both a thread's own
// Messages and the Threads slice itself by its newest member, so the
// result is a total order and repeated derivations over the same input are
// byte-identical.
func isNewer(a, b source.Message) bool {
	if a.At != b.At {
		return a.At > b.At
	}
	return a.ID > b.ID
}

// threadKey computes one message's thread key: the sorted, de-duplicated
// union of its FromAddress and ToAddresses. A self-addressed envelope
// (From == To) dedupes to one address rather than a doubled composite. An
// envelope with no address fields at all (a pre-sp033-T1 payload) keys on
// the empty string, per Task 1's edge case -- it forms its own degenerate
// thread instead of being dropped.
func threadKey(m source.Message) string {
	seen := make(map[string]struct{}, len(m.ToAddresses)+1)
	seen[m.FromAddress] = struct{}{}
	for _, a := range m.ToAddresses {
		seen[a] = struct{}{}
	}
	addrs := make([]string, 0, len(seen))
	for a := range seen {
		addrs = append(addrs, a)
	}
	sort.Strings(addrs)
	return strings.Join(addrs, threadKeySep)
}

// participantLabels resolves one display label per address in a thread's
// key (already the sorted set), from the thread's own messages.
// FromAddress/From is always a safe pairing (both scalar -- no length
// mismatch is possible). ToAddresses[i]/To[i] is paired positionally only
// when the two slices are the same length for that message; a mismatched
// message contributes no To-side labels at all, so an untrustworthy
// pairing never produces a wrong label. msgs is newest-first, and the
// first message to supply a label for an address wins the map -- the
// known limitation that a party renamed mid-conversation shows its most
// recent label.
func participantLabels(key string, msgs []source.Message) []string {
	addrs := strings.Split(key, threadKeySep)

	labels := make(map[string]string, len(addrs))
	for _, m := range msgs {
		if m.FromAddress != "" && m.From != "" {
			if _, ok := labels[m.FromAddress]; !ok {
				labels[m.FromAddress] = m.From
			}
		}
		if len(m.To) != len(m.ToAddresses) {
			continue
		}
		for i, addr := range m.ToAddresses {
			if addr == "" || m.To[i] == "" {
				continue
			}
			if _, ok := labels[addr]; !ok {
				labels[addr] = m.To[i]
			}
		}
	}

	out := make([]string, len(addrs))
	for i, addr := range addrs {
		if label, ok := labels[addr]; ok {
			out[i] = label
		} else {
			out[i] = shortAddress(addr)
		}
	}
	return out
}

// Threads groups msgs by threadKey and returns them ordered by their
// newest member, newest-first; each Thread's own Messages are newest-first
// too. msgs is never mutated -- every message that gets sorted is sorted
// in a fresh copy, and msgs itself is only ever ranged over.
func Threads(msgs []source.Message) []Thread {
	byKey := make(map[string][]source.Message, len(msgs))
	var keys []string
	for _, m := range msgs {
		k := threadKey(m)
		if _, ok := byKey[k]; !ok {
			keys = append(keys, k)
		}
		byKey[k] = append(byKey[k], m)
	}

	threads := make([]Thread, 0, len(keys))
	for _, k := range keys {
		group := byKey[k]
		sorted := make([]source.Message, len(group))
		copy(sorted, group)
		sort.SliceStable(sorted, func(i, j int) bool { return isNewer(sorted[i], sorted[j]) })

		threads = append(threads, Thread{
			Key:          k,
			Messages:     sorted,
			Count:        len(sorted),
			Participants: participantLabels(k, sorted),
		})
	}

	sort.SliceStable(threads, func(i, j int) bool {
		return isNewer(threads[i].Messages[0], threads[j].Messages[0])
	})

	return threads
}
