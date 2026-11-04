//go:build !unix

package xsel

// Lock is a no-op where flock does not exist; the X agent only runs on
// unix hosts.
func Lock(path string) (release func(), ok bool, err error) { return func() {}, true, nil }
