import ListnrCore

// The entire CLI lives in `ListnrCore` so that the logic is importable — by the
// test target, and by the menubar app on the roadmap, which needs the session
// pipeline and cannot import an executable target. This file is the whole
// executable: everything it does is hand control to the root command.
Listnr.main()
