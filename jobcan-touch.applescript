#!/usr/bin/osascript

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Jobcan touch
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 💼

# Documentation:
# @raycast.description Jobcanで打刻

use framework "Foundation"

on keychainSlackURL()
    set keychainTask to current application's NSTask's alloc()'s init()
    keychainTask's setLaunchPath:"/usr/bin/security"
    keychainTask's setArguments:{"find-generic-password", "-s", "my.slack.url-dm-myself", "-a", "my", "-w"}
    set outputPipe to current application's NSPipe's pipe()
    keychainTask's setStandardOutput:outputPipe

    try
        keychainTask's |launch|()
        keychainTask's waitUntilExit()
    on error
        return ""
    end try

    if keychainTask's terminationStatus() is not 0 then return ""

    set outputData to outputPipe's fileHandleForReading()'s readDataToEndOfFile()
    set outputString to current application's NSString's alloc()'s initWithData:outputData encoding:(current application's NSUTF8StringEncoding)
    if outputString is missing value then return ""
    return (outputString's stringByTrimmingCharactersInSet:(current application's NSCharacterSet's whitespaceAndNewlineCharacterSet())) as text
end keychainSlackURL

set slackURL to keychainSlackURL()
if slackURL is "" then return

tell application "Slack" 
    activate
    delay 0.5
    open location (slackURL)
    delay 0.5
    tell application "System Events"
        set the clipboard to "/jobcan_touch"
        keystroke "v" using {command down}
        delay 0.5
        key code 36
        key code 36 using {command down}
    end tell
end tell
