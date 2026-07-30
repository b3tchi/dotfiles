package x11

import "testing"

func TestReconstructSeq(t *testing.T) {
	cases := []struct {
		name     string
		lastFull uint64
		wireLow  uint16
		want     uint64
	}{
		{name: "exact match, no wrap", lastFull: 5, wireLow: 5, want: 5},
		{name: "same generation, subtract back", lastFull: 70010, wireLow: 4470, want: 70006},
		{
			name:     "one wrap boundary, resolves to the FRESH post-wrap sequence",
			lastFull: 65541, // low16 == 5, one generation past the raw value 5
			wireLow:  5,
			want:     65541, // NOT 5 -- gotcha 10: a stale low-16 must not win
		},
		{
			name:     "two wraps",
			lastFull: 131077, // 2*65536 + 5
			wireLow:  5,
			want:     131077,
		},
		{
			name:     "wireLow ahead of lastLow within one generation (no wrap needed)",
			lastFull: 70000, // low16 = 4464
			wireLow:  60000,
			want:     60000,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := reconstructSeq(tc.lastFull, tc.wireLow)
			if got != tc.want {
				t.Errorf("reconstructSeq(%d, %d) = %d, want %d", tc.lastFull, tc.wireLow, got, tc.want)
			}
		})
	}
}
