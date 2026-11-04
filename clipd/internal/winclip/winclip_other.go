//go:build !windows

package winclip

// Stubs so packages that wire the Windows agent build (and test with a fake
// clipboard) everywhere. Every call reports ErrUnsupported.

type Listener struct{}

func Listen() (*Listener, error)        { return nil, ErrUnsupported }
func (*Listener) Events() <-chan struct{} { return nil }
func (*Listener) Close()                 {}

func Seq() uint32 { return 0 }

type Clipboard struct{}

func (Clipboard) Seq() uint32                    { return 0 }
func (Clipboard) View(fn func(View) error) error { return ErrUnsupported }

type View struct{}

func (View) Formats() ([]Format, error)    { return nil, ErrUnsupported }
func (View) Text(max int) ([]byte, error)  { return nil, ErrUnsupported }
func (View) Image(max int) ([]byte, error) { return nil, ErrUnsupported }

func Publish(isPNG bool, data []byte) error { return ErrUnsupported }
