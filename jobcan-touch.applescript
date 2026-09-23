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

on isValidSlackIdentifier(candidateValue)
    if candidateValue is "" then return false

    set allowedCharacters to "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    repeat with candidateCharacter in characters of candidateValue
        set characterText to candidateCharacter as text
        if allowedCharacters does not contain characterText then return false
    end repeat

    return true
end isValidSlackIdentifier

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

on isValidSlackURL(candidateURL)
    if class of candidateURL is not text then return false

    set urlPrefix to "slack://channel?team="

    if candidateURL is "" then return false
    if candidateURL does not start with urlPrefix then return false
    if (length of candidateURL) <= (length of urlPrefix) then return false

    set queryValues to text ((length of urlPrefix) + 1) thru -1 of candidateURL
    set queryLength to length of queryValues
    if queryLength < 4 then return false

    set separatorOffset to 0
    set markerPosition to 1
    repeat while (markerPosition + 3) <= queryLength
        if text markerPosition thru (markerPosition + 3) of queryValues is "&id=" then
            set separatorOffset to markerPosition
            exit repeat
        end if
        set markerPosition to markerPosition + 1
    end repeat

    if separatorOffset is 0 then return false
    if separatorOffset is 1 then return false
    if (separatorOffset + 4) > queryLength then return false

    set teamValue to text 1 thru (separatorOffset - 1) of queryValues
    set idValue to text (separatorOffset + 4) thru -1 of queryValues

    if not isValidSlackIdentifier(teamValue) then return false
    if not isValidSlackIdentifier(idValue) then return false
    if candidateURL is not (urlPrefix & teamValue & "&id=" & idValue) then return false

    return true
end isValidSlackURL

on run argv
    -- Keychain is the only destination source; lookup failure has no UI effects.
    set slackURL to keychainSlackURL()

    if not isValidSlackURL(slackURL) then return

    tell application "Slack"
        activate
        delay 0.5
    end tell

    set slackURLObject to current application's NSURL's URLWithString:slackURL
    if slackURLObject is missing value then return
    set workspaceObject to current application's NSWorkspace's sharedWorkspace()
    if not (workspaceObject's openURL:slackURLObject) then return
    delay 1

    tell application "System Events"
        set the clipboard to "/jobcan_touch"
        keystroke "v" using {command down}
        delay 0.5
        key code 36
    end tell
end run
