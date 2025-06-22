;============================================================
;             PSM AutoIt Firefox Dispatcher
;             ------------------------------
;
; This is a firefox dispatcher
; connection components integrated with the PSM.
; Areas you may want to modify are marked
; with the string "CHANGE_ME".
;
; Created : June 2025
; Pr0digal
;============================================================

#AutoIt3Wrapper_UseX64=y
Opt("MustDeclareVars", 1)
AutoItSetOption("WinTitleMatchMode", 3)

#include "PSMGenericClientWrapper.au3"

Global Const $DISPATCHER_NAME         = "Firefox Dispatcher"
Global Const $ERROR_MESSAGE_TITLE     = "PSM " & $DISPATCHER_NAME & " Dispatcher error message"
Global Const $LOG_MESSAGE_PREFIX      = $DISPATCHER_NAME & " - "
Global $TargetUsername
Global $TargetPassword
Global $TargetAddress
Global $ConnectionClientPID = 0

Global Const $CLIENT_EXECUTABLE = "CHANGE_ME"
Global Const $DEBUG_LOG = @TempDir & "\firefox_psm_debug.txt"

Exit Main()

Func Main()
    ToolTip("Initializing...")
    FileWrite($DEBUG_LOG, "🔧 Dispatcher started" & @CRLF)

    If (PSMGenericClient_Init() <> $PSM_ERROR_SUCCESS) Then
        Error(PSMGenericClient_PSMGetLastErrorString())
    EndIf

    LogWrite("Successfully initialized dispatcher utils")
    FetchSessionProperties()

    LogWrite("Launching Firefox with: " & $TargetAddress)
    FileWrite($DEBUG_LOG, "Target Address: " & $TargetAddress & @CRLF)
    FileWrite($DEBUG_LOG, "Firefox Path: " & $CLIENT_EXECUTABLE & @CRLF)

    If Not FileExists($CLIENT_EXECUTABLE) Then
        FileWrite($DEBUG_LOG, "❌ Firefox not found at path" & @CRLF)
        Error("Firefox not found at: " & $CLIENT_EXECUTABLE)
    EndIf

    ; Use fallback shell-based launcher
    $ConnectionClientPID = ShellExecute($CLIENT_EXECUTABLE, $TargetAddress)
    FileWrite($DEBUG_LOG, "ShellExecute PID: " & $ConnectionClientPID & @CRLF)

    If $ConnectionClientPID = 0 Then
        Error("Failed to start Firefox via ShellExecute")
    EndIf

    If (PSMGenericClient_SendPID($ConnectionClientPID) <> $PSM_ERROR_SUCCESS) Then
        Error(PSMGenericClient_PSMGetLastErrorString())
    EndIf

    ToolTip("Waiting for Firefox window...")
    If Not WinWait("[CLASS:MozillaWindowClass]", "", 30) Then
        Error("Timeout: Firefox window not detected")
    EndIf

    WinActivate("[CLASS:MozillaWindowClass]")
    WinWaitActive("[CLASS:MozillaWindowClass]", "", 5)

    LogWrite("Firefox window is active. Waiting for page render...")
    Sleep(8000)

    ; Try to close password manager bar
    Send("{ESC}")
    Sleep(300)

    ; Ensure keyboard focus into page
    MouseClick("left", @DesktopWidth / 2, @DesktopHeight / 2, 1)
    Sleep(300)
    Send("^{HOME}")
    Sleep(300)

    ; Send credentials (username, TAB, password, ENTER)
    Send($TargetUsername)
    Sleep(100)
    Send("{TAB}")
    Sleep(100)
    Send($TargetPassword)
    Sleep(100)
    Send("{ENTER}")

    LogWrite("Credentials sent successfully")
    ToolTip("Login automation complete.")
    Sleep(4000)

    PSMGenericClient_Term()
    Return $PSM_ERROR_SUCCESS
EndFunc

Func FetchSessionProperties()
    If (PSMGenericClient_GetSessionProperty("Address", $TargetAddress) <> $PSM_ERROR_SUCCESS) Then
        Error(PSMGenericClient_PSMGetLastErrorString())
    EndIf
    If (PSMGenericClient_GetSessionProperty("Username", $TargetUsername) <> $PSM_ERROR_SUCCESS) Then
        Error(PSMGenericClient_PSMGetLastErrorString())
    EndIf
    If (PSMGenericClient_GetSessionProperty("Password", $TargetPassword) <> $PSM_ERROR_SUCCESS) Then
        Error(PSMGenericClient_PSMGetLastErrorString())
    EndIf
EndFunc

Func LogWrite($sMessage, $LogLevel = $LOG_LEVEL_TRACE)
    FileWrite($DEBUG_LOG, "📝 " & $sMessage & @CRLF)
    Return PSMGenericClient_LogWrite($LOG_MESSAGE_PREFIX & $sMessage, $LogLevel)
EndFunc

Func Error($ErrorMessage, $Code = -1)
    FileWrite($DEBUG_LOG, "❗ ERROR: " & $ErrorMessage & @CRLF)

    If (PSMGenericClient_IsInitialized()) Then
        LogWrite($ErrorMessage, True)
        PSMGenericClient_Term()
    EndIf

    MsgBox(16 + 262144, $ERROR_MESSAGE_TITLE, $ErrorMessage)

    If ($ConnectionClientPID <> 0) Then
        ProcessClose($ConnectionClientPID)
        $ConnectionClientPID = 0
    EndIf

    Exit $Code
EndFunc
