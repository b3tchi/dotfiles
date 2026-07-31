package layer

import "time"

// Harness-only surface on StatePublisher (dotfiles-ylmp.16).
//
// WHY THIS IS A SEPARATE FILE. Everything in publisher.go is called by the
// daemon. Nothing in here is — the sole caller is cmd/statepub, the bind-free
// publisher fixture quickshell/test-mode-bar.sh drives to exercise the bar
// against a real hotkeyd state socket. Keeping it out of publisher.go means
// nobody reading the daemon's publisher has to work out which methods the
// daemon actually uses, and a future reader who wants to delete this knows
// exactly what depends on it.
//
// WHY IT EXISTS AT ALL. test-mode-bar.sh must prove the BAR survives a
// malformed line on the state socket: a bar that blanked its mode pill on a
// parse error would leave the user with no idea which layer holds their
// keyboard. That test needs bytes on the wire that the publisher would never
// legitimately emit, so it cannot be expressed through Publish, which only
// takes a well-formed State. Python's fixture got this by reaching into
// `pub._clients` from outside the class; Go has no such back door, so the
// capability is a named method instead of an encapsulation break.
//
// The alternative — having the fixture bind its own unix socket and speak the
// wire format by hand — was rejected: it would make the harness a SECOND
// implementation of the protocol, free to drift from the one the daemon
// actually runs, which is the exact property the fixture exists to rule out.

// WriteRawLine sends s to every connected client verbatim, with a trailing
// newline appended and no JSON encoding, and returns the number of clients
// written to. Clients whose write fails are dropped and closed, exactly as
// Publish drops them — a fixture must not leak the fd of a dead bar any more
// than the daemon may.
//
// Does NOT update the replayed state: a garbage line is by definition not a
// state, so a client connecting afterwards must still be replayed the last
// real one. That asymmetry with Publish is the point, and it is what lets the
// suite assert that a bar which reconnects after garbage recovers the TRUE
// layer rather than inheriting the noise.
func (p *StatePublisher) WriteRawLine(s string) int {
	line := []byte(s + "\n")

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return 0
	}
	n := 0
	for conn := range p.clients {
		if err := conn.SetWriteDeadline(time.Now().Add(writeTimeout)); err != nil {
			delete(p.clients, conn)
			_ = conn.Close()
			continue
		}
		if _, err := conn.Write(line); err != nil {
			delete(p.clients, conn)
			_ = conn.Close()
			continue
		}
		n++
	}
	return n
}
