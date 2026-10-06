package conns

import (
	"context"
	"sync"
	"testing"
)

func ended(ctx context.Context) bool {
	select {
	case <-ctx.Done():
		return true
	default:
		return false
	}
}

func TestCloseDeviceEndsOnlyThatDevice(t *testing.T) {
	r := New()
	a1, relA1 := r.Track(context.Background(), "a")
	a2, relA2 := r.Track(context.Background(), "a")
	b, relB := r.Track(context.Background(), "b")
	defer relA1()
	defer relA2()
	defer relB()

	if n := r.CloseDevice("a"); n != 2 {
		t.Fatalf("closed %d, want 2", n)
	}
	if !ended(a1) || !ended(a2) {
		t.Fatal("a request of the closed device is still open")
	}
	if ended(b) {
		t.Fatal("another device was closed too")
	}
	if n := r.CloseDevice("a"); n != 0 {
		t.Fatalf("second close reported %d", n)
	}
	if n := r.CloseDevice("unknown"); n != 0 {
		t.Fatalf("unknown device reported %d", n)
	}
}

func TestReleaseForgetsTheRequest(t *testing.T) {
	r := New()
	ctx, release := r.Track(context.Background(), "a")
	if r.Open("a") != 1 {
		t.Fatalf("open = %d", r.Open("a"))
	}
	release()
	if r.Open("a") != 0 {
		t.Fatalf("open after release = %d", r.Open("a"))
	}
	if !ended(ctx) {
		t.Fatal("release left the context open")
	}
	release() // twice is harmless
}

func TestTheParentEndingEndsTheRequest(t *testing.T) {
	r := New()
	parent, cancel := context.WithCancel(context.Background())
	ctx, release := r.Track(parent, "a")
	defer release()
	cancel()
	if !ended(ctx) {
		t.Fatal("the request outlived its parent")
	}
}

func TestCloseAllEndsEverythingAndRefusesNewRequests(t *testing.T) {
	r := New()
	a, relA := r.Track(context.Background(), "a")
	b, relB := r.Track(context.Background(), "b")
	defer relA()
	defer relB()
	r.CloseAll()
	if !ended(a) || !ended(b) {
		t.Fatal("a request survived CloseAll")
	}
	late, relLate := r.Track(context.Background(), "a")
	defer relLate()
	if !ended(late) {
		t.Fatal("a request started after CloseAll is open")
	}
}

func TestConcurrentUse(t *testing.T) {
	r := New()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, release := r.Track(context.Background(), "a")
			r.Open("a")
			r.CloseDevice("a")
			release()
		}()
	}
	wg.Wait()
	if r.Open("a") != 0 {
		t.Fatalf("open = %d after everything was released", r.Open("a"))
	}
}
