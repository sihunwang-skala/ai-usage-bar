import AppKit

// LaunchAgent로 실행되면 stdout이 파일이라 블록 버퍼링된다. 로그가 바로 보이도록 줄 단위로 바꾼다.
setvbuf(stdout, nil, _IOLBF, 0)

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
