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

on launchdEnvironmentValue(environmentKey)
    set launchTask to current application's NSTask's alloc()'s init()
    launchTask's setLaunchPath:"/bin/launchctl"
    launchTask's setArguments:{"getenv", environmentKey}
    set outputPipe to current application's NSPipe's pipe()
    launchTask's setStandardOutput:outputPipe
    launchTask's |launch|()
    launchTask's waitUntilExit()
    set outputData to outputPipe's fileHandleForReading()'s readDataToEndOfFile()
    set outputString to current application's NSString's alloc()'s initWithData:outputData encoding:(current application's NSUTF8StringEncoding)
    if outputString is missing value then return ""
    return (outputString's stringByTrimmingCharactersInSet:(current application's NSCharacterSet's whitespaceAndNewlineCharacterSet())) as text
end launchdEnvironmentValue

on isValidSlackIdentifier(candidateValue)
    if class of candidateValue is not text then return false
    if candidateValue is "" then return false

    set allowedCharacters to "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    repeat with candidateCharacter in characters of candidateValue
        set characterText to candidateCharacter as text
        if allowedCharacters does not contain characterText then return false
    end repeat

    return true
end isValidSlackIdentifier

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

on slackURLParts(candidateURL)
    set urlPrefix to "slack://channel?team="
    set queryValues to text ((length of urlPrefix) + 1) thru -1 of candidateURL
    set separatorOffset to 0
    set markerPosition to 1
    repeat while (markerPosition + 3) is less than or equal to (length of queryValues)
        if text markerPosition thru (markerPosition + 3) of queryValues is "&id=" then
            set separatorOffset to markerPosition
            exit repeat
        end if
        set markerPosition to markerPosition + 1
    end repeat
    if separatorOffset is 0 then error "invalid Slack URL parts"
    set teamValue to text 1 thru (separatorOffset - 1) of queryValues
    set idValue to text (separatorOffset + 4) thru -1 of queryValues
    return {workspaceIdentifier:teamValue, conversationIdentifier:idValue}
end slackURLParts

on executeJobcanFlow(adapter)
    set guardAcquired to false
    set pasteboardBackedUp to false
    set pasteboardSnapshot to missing value
    set capturedError to missing value

    try
        set guardAcquired to adapter's acquireSingleRunGuard()
        if guardAcquired then
            adapter's activateSlack()
            adapter's openConfiguredConversation()
            if adapter's waitForComposer() then
                set pasteboardSnapshot to adapter's backupPasteboard()
                set pasteboardBackedUp to true
                adapter's writeCommandToPasteboard("/jobcan_touch")
                adapter's focusComposerAndPaste()
                adapter's sendCommand()
            end if
        end if
    on error errorMessage number errorNumber
        set capturedError to {errorMessage, errorNumber}
    end try

    if pasteboardBackedUp then
        try
            adapter's restorePasteboard(pasteboardSnapshot)
        on error restoreMessage number restoreNumber
            if capturedError is missing value then set capturedError to {restoreMessage, restoreNumber}
        end try
    end if

    if guardAcquired then
        try
            adapter's releaseSingleRunGuard()
        on error releaseMessage number releaseNumber
            if capturedError is missing value then set capturedError to {releaseMessage, releaseNumber}
        end try
    end if

    if capturedError is not missing value then error (item 1 of capturedError) number (item 2 of capturedError)
end executeJobcanFlow

script productionAdapter
    property configuredSlackURL : ""
    property workspaceIdentifier : ""
    property conversationIdentifier : ""
    property targetHTMLContent : missing value
    property composerElement : missing value
    property runLock : missing value

    on acquireSingleRunGuard()
        set urlParts to slackURLParts(my configuredSlackURL)
        set my workspaceIdentifier to workspaceIdentifier of urlParts
        set my conversationIdentifier to conversationIdentifier of urlParts

        set lockPath to ((current application's NSTemporaryDirectory()) as text) & "jobcan-touch.lock"
        set my runLock to current application's NSDistributedLock's lockWithPath:lockPath
        if (my runLock's tryLock()) then return true

        set lockDate to my runLock's lockDate()
        if lockDate is missing value then return false

        set nowDate to current application's NSDate's date()
        set lockAge to nowDate's timeIntervalSinceDate:lockDate
        if lockAge is greater than 120 then
            my runLock's breakLock()
            set my runLock to current application's NSDistributedLock's lockWithPath:lockPath
            return my runLock's tryLock()
        end if

        return false
    end acquireSingleRunGuard

    on activateSlack()
        tell application "Slack" to activate
    end activateSlack

    on openConfiguredConversation()
        set slackURLObject to current application's NSURL's URLWithString:(my configuredSlackURL)
        if slackURLObject is missing value then error "invalid Slack URL object"
        set workspaceObject to current application's NSWorkspace's sharedWorkspace()
        if not (workspaceObject's openURL:slackURLObject) then error "could not open configured Slack conversation"
    end openConfiguredConversation

    on waitForComposer()
        set timeoutSeconds to 8
        set deadline to current application's NSDate's dateWithTimeIntervalSinceNow:timeoutSeconds

        repeat while (deadline's timeIntervalSinceNow()) is greater than 0
            set candidate to my findTargetComposer()
            if candidate is not missing value then
                set my composerElement to candidate
                return true
            end if
            delay 0.1
        end repeat

        return false
    end waitForComposer

    on backupPasteboard()
        set pasteboard to current application's NSPasteboard's generalPasteboard()
        set snapshot to current application's NSMutableArray's array()

        repeat with pasteboardItem in (pasteboard's pasteboardItems())
            set itemSnapshot to current application's NSMutableDictionary's dictionary()
            set typeSnapshot to current application's NSMutableDictionary's dictionary()

            repeat with typeIdentifier in (pasteboardItem's types())
                set typeText to typeIdentifier as text
                set typeData to pasteboardItem's dataForType:typeText
                if typeData is not missing value then typeSnapshot's setObject:typeData forKey:typeText
            end repeat

            itemSnapshot's setObject:typeSnapshot forKey:"representations"
            snapshot's addObject:itemSnapshot
        end repeat

        return snapshot
    end backupPasteboard

    on writeCommandToPasteboard(commandText)
        set pasteboard to current application's NSPasteboard's generalPasteboard()
        if not (pasteboard's clearContents()) then error "could not clear pasteboard"
        if not (pasteboard's setString:commandText forType:(current application's NSPasteboardTypeString)) then error "could not set command pasteboard"
    end writeCommandToPasteboard

    on focusComposerAndPaste()
        set currentComposer to my findTargetComposer()
        if currentComposer is missing value then error "target composer is no longer ready"
        set my composerElement to currentComposer

        tell application "System Events"
            tell process "Slack"
                set focused of currentComposer to true
                if not (focused of currentComposer) then error "could not focus target composer"
                keystroke "a" using {command down}
                keystroke "v" using {command down}
            end tell
        end tell
    end focusComposerAndPaste

    on sendCommand()
        set currentComposer to my findTargetComposer()
        if currentComposer is missing value then error "target composer is no longer ready"
        set sendButton to my findSendButton(currentComposer)
        if sendButton is missing value then error "target Slack send button is not available"

        tell application "System Events"
            tell process "Slack"
                if not (enabled of sendButton) then error "target Slack send button is disabled"
                click sendButton
            end tell
        end tell
    end sendCommand

    on restorePasteboard(snapshot)
        set pasteboard to current application's NSPasteboard's generalPasteboard()
        set restoredItems to current application's NSMutableArray's array()

        repeat with itemSnapshot in snapshot
            set restoredItem to current application's NSPasteboardItem's alloc()'s init()
            set typeSnapshot to itemSnapshot's objectForKey:"representations"
            repeat with typeIdentifier in (typeSnapshot's allKeys())
                set typeData to typeSnapshot's objectForKey:typeIdentifier
                restoredItem's setData:typeData forType:(typeIdentifier as text)
            end repeat
            restoredItems's addObject:restoredItem
        end repeat

        set restoreClearResult to pasteboard's clearContents()
        if restoreClearResult is false then
            error "could not clear pasteboard for restore"
        end if
        set restoredCount to restoredItems's |count|()
        if restoredCount is greater than 0 then
            set restoreWriteResult to pasteboard's writeObjects:restoredItems
            if restoreWriteResult is false then
                error "could not restore pasteboard items"
            end if
        end if
    end restorePasteboard

    on releaseSingleRunGuard()
        if my runLock is not missing value then
            my runLock's unlock()
            set my runLock to missing value
        end if
    end releaseSingleRunGuard

    on findTargetComposer()
        tell application "System Events"
            tell process "Slack"
                if (count of windows) is 0 then return missing value
                set slackWindow to window 1
                set targetHTML to my findTargetHTML(slackWindow)
                if targetHTML is missing value then return missing value
                if my hasBlockingModal(slackWindow) then return missing value

                set composers to every UI element of entire contents of targetHTML whose role description is "text entry area"
                set matchingComposers to {}
                repeat with composerCandidate in composers
                    try
                        set composerDescription to description of composerCandidate
                        set editableValue to value of attribute "AXEditable" of composerCandidate
                        set enabledValue to value of attribute "AXEnabled" of composerCandidate
                        if (composerDescription starts with "Message to ") and editableValue and enabledValue then set end of matchingComposers to contents of composerCandidate
                    end try
                end repeat

                if (count of matchingComposers) is not 1 then return missing value
                return item 1 of matchingComposers
            end tell
        end tell
    end findTargetComposer

    on findTargetHTML(slackWindow)
        tell application "System Events"
            tell process "Slack"
                set htmlCandidates to every UI element of entire contents of slackWindow whose role description is "HTML content"
                repeat with htmlCandidate in htmlCandidates
                    try
                        set candidateURL to (value of attribute "AXURL" of htmlCandidate) as text
                        if candidateURL contains ("/client/" & my workspaceIdentifier & "/" & my conversationIdentifier) then return contents of htmlCandidate
                    end try
                end repeat
                return missing value
            end tell
        end tell
    end findTargetHTML

    on hasBlockingModal(slackWindow)
        tell application "System Events"
            tell process "Slack"
                set dialogs to every UI element of entire contents of slackWindow whose role description is "dialog"
                set sheets to every sheet of slackWindow
                return ((count of dialogs) is greater than 0) or ((count of sheets) is greater than 0)
            end tell
        end tell
    end hasBlockingModal

    on findSendButton(composer)
        tell application "System Events"
            tell process "Slack"
                set currentParent to composer
                repeat 5 times
                    try
                        set currentParent to parent of currentParent
                        set sendButtons to every button of entire contents of currentParent whose description is "Send now"
                        if (count of sendButtons) is 1 then return item 1 of sendButtons
                    on error
                        exit repeat
                    end try
                end repeat
                return missing value
            end tell
        end tell
    end findSendButton
end script

on run argv
    set processEnvironment to current application's NSProcessInfo's processInfo()'s environment()
    set slackURLValue to processEnvironment's objectForKey:"JOBCAN_SLACK_URL"
    if slackURLValue is missing value then
        set slackURL to launchdEnvironmentValue("JOBCAN_SLACK_URL")
    else
        set slackURL to slackURLValue as text
    end if

    if not isValidSlackURL(slackURL) then return

    set productionAdapter's configuredSlackURL to slackURL
    executeJobcanFlow(productionAdapter)
end run
