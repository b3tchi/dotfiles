package proc

import "testing"

func TestNormalizeDisplay(t *testing.T) {
	cases := []struct {
		name    string
		display string
		want    string
	}{
		{"bare display", ":0", "0"},
		{"rdp screen suffix stripped", ":10.0", "10"},
		{"no leading colon", "10", "10"},
		{"multiple leading colons", "::10", "10"},
		{"multi-digit with suffix", ":123.4", "123"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := NormalizeDisplay(c.display)
			if got != c.want {
				t.Fatalf("NormalizeDisplay(%q) = %q, want %q", c.display, got, c.want)
			}
		})
	}
}
