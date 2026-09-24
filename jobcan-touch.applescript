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
use framework "AppKit"
use scripting additions

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

on isValidSlackIdentifier(candidateValue)
    try
        set candidateText to candidateValue as text
    on error
        return false
    end try
    if candidateText is "" then return false

    set allowedCharacters to "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    repeat with characterReference in characters of candidateText
        set candidateCharacter to contents of characterReference
        if allowedCharacters does not contain candidateCharacter then return false
    end repeat
    return true
end isValidSlackIdentifier

on isValidSlackURL(candidateURL)
    try
        set candidateText to candidateURL as text
    on error
        return false
    end try

    set urlPrefix to "slack://channel?team="
    set identifierSeparator to "&id="
    if candidateText does not start with urlPrefix then return false

    set payload to text ((count of urlPrefix) + 1) thru -1 of candidateText
    set previousDelimiters to AppleScript's text item delimiters
    try
        set AppleScript's text item delimiters to identifierSeparator
        set urlParts to text items of payload
    on error
        set AppleScript's text item delimiters to previousDelimiters
        return false
    end try
    set AppleScript's text item delimiters to previousDelimiters

    if (count of urlParts) is not 2 then return false
    if not my isValidSlackIdentifier(item 1 of urlParts) then return false
    if not my isValidSlackIdentifier(item 2 of urlParts) then return false
    return true
end isValidSlackURL

on jobcanLockPath()
    return ((current application's NSHomeDirectory()) as text) & "/Library/Application Support/my.jobcan.touch.lock"
end jobcanLockPath

on tryAcquireJobcanLock(lockPath)
    set lockObject to current application's NSDistributedLock's alloc()'s initWithPath:(lockPath as text)
    if lockObject is missing value then return missing value
    if lockObject's tryLock() then return lockObject
    return missing value
end tryAcquireJobcanLock

on releaseJobcanLock(lockObject)
    if lockObject is not missing value then lockObject's unlock()
    return true
end releaseJobcanLock

on runSafeJobcanTouch(candidateURL, lockPath, effects)
    if not my isValidSlackURL(candidateURL) then return "blocked_invalid_url"

    set lockObject to my tryAcquireJobcanLock(lockPath)
    if lockObject is missing value then return "blocked_duplicate"

    try
        set operationResult to effects's performJobcanTouch(candidateURL)
        my releaseJobcanLock(lockObject)
        return operationResult
    on error
        try
            my releaseJobcanLock(lockObject)
        end try
        return "operation_failed"
    end try
end runSafeJobcanTouch

on snapshotJobcanPasteboard(pasteboard)
    set originalItems to pasteboard's pasteboardItems()
    if originalItems is missing value then return current application's NSMutableArray's array()

    set snapshot to current application's NSMutableArray's array()
    repeat with itemReference in originalItems
        set pasteboardItem to contents of itemReference
        set itemTypes to pasteboardItem's types()
        if itemTypes is missing value then return missing value

        set itemData to current application's NSMutableArray's array()
        repeat with typeReference in itemTypes
            set pasteboardType to contents of typeReference
            set representationData to pasteboardItem's dataForType:pasteboardType
            if representationData is missing value then return missing value
            itemData's addObject:representationData
        end repeat
        set itemSnapshot to {itemTypes, itemData}
        snapshot's addObject:itemSnapshot
    end repeat
    return snapshot
end snapshotJobcanPasteboard

on restoreJobcanPasteboard(pasteboard, snapshot)
    set restoredItems to current application's NSMutableArray's array()
    repeat with snapshotReference in snapshot
        set itemSnapshot to contents of snapshotReference
        set itemTypes to item 1 of itemSnapshot
        set itemData to item 2 of itemSnapshot
        set restoredItem to current application's NSPasteboardItem's alloc()'s init()

        repeat with itemIndex from 1 to (count of itemTypes)
            set pasteboardType to item itemIndex of itemTypes
            set representationData to item itemIndex of itemData
            if (restoredItem's setData:representationData forType:pasteboardType) is false then return false
        end repeat
        restoredItems's addObject:restoredItem
    end repeat

    if (count of restoredItems) is 0 then
        pasteboard's clearContents()
        return true
    end if
    return pasteboard's writeObjects:restoredItems
end restoreJobcanPasteboard

on jobcanPasteboardSnapshotsMatch(expectedSnapshot, actualSnapshot)
    if (count of expectedSnapshot) is not (count of actualSnapshot) then return false
    repeat with itemIndex from 1 to (count of expectedSnapshot)
        set expectedItem to item itemIndex of expectedSnapshot
        set actualItem to item itemIndex of actualSnapshot
        set expectedTypes to item 1 of expectedItem
        set actualTypes to item 1 of actualItem
        set expectedData to item 2 of expectedItem
        set actualData to item 2 of actualItem
        if expectedTypes is not equal to actualTypes then return false
        if (count of expectedData) is not (count of actualData) then return false
        repeat with typeIndex from 1 to (count of expectedData)
            set expectedRepresentation to item typeIndex of expectedData
            set actualRepresentation to item typeIndex of actualData
            if (expectedRepresentation's isEqualToData:actualRepresentation) is false then return false
        end repeat
    end repeat
    return true
end jobcanPasteboardSnapshotsMatch

on performJobcanTouch(candidateURL)
    set pasteboard to current application's NSPasteboard's generalPasteboard()
    set countBeforeSnapshot to pasteboard's changeCount()
    set originalSnapshot to my snapshotJobcanPasteboard(pasteboard)
    if originalSnapshot is missing value then return "blocked_clipboard_snapshot"

    set countAfterSnapshot to pasteboard's changeCount()
    if countAfterSnapshot is not countBeforeSnapshot then return "blocked_clipboard_conflict"

    set commandItem to current application's NSPasteboardItem's alloc()'s init()
    if (commandItem's setString:"/jobcan_touch" forType:(current application's NSPasteboardTypeString)) is false then return "blocked_clipboard_write"
    set commandItems to current application's NSMutableArray's array()
    commandItems's addObject:commandItem
    set writeSucceeded to pasteboard's writeObjects:commandItems
    set countAfterCommand to pasteboard's changeCount()
    if writeSucceeded is false then return "blocked_clipboard_write"
    if countAfterCommand is not (countAfterSnapshot + 1) then return "blocked_clipboard_conflict"

    set operationResult to "performed"
    try
        tell application "Slack"
            activate
            delay 0.5
            open location (candidateURL)
            delay 0.5
            tell application "System Events"
                keystroke "v" using {command down}
                delay 0.5
                key code 36
                key code 36 using {command down}
            end tell
        end tell
    on error
        set operationResult to "operation_failed"
    end try

    if (pasteboard's changeCount()) is not countAfterCommand then return "clipboard_restore_conflict"
    try
        if (my restoreJobcanPasteboard(pasteboard, originalSnapshot)) is false then return "clipboard_restore_failed"
        set restoredSnapshot to my snapshotJobcanPasteboard(pasteboard)
        if restoredSnapshot is missing value then return "clipboard_restore_failed"
        if not my jobcanPasteboardSnapshotsMatch(originalSnapshot, restoredSnapshot) then return "clipboard_restore_failed"
    on error
        return "clipboard_restore_failed"
    end try
    return operationResult
end performJobcanTouch

on run argv
    set slackURL to my keychainSlackURL()
    set lockPath to my jobcanLockPath()
    return my runSafeJobcanTouch(slackURL, lockPath, me)
end run
