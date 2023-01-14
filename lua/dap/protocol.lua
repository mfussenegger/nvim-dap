---@class dap.Thread
---@field id number
---@field name string
---@field frames nil|dap.StackFrame[] not part of the spec; added by nvim-dap
---@field stopped nil|boolean not part of the spec; added by nvim-dap

---@class dap.ErrorResponse
---@field message string
---@field body dap.ErrorBody


---@class dap.ErrorBody
---@field error nil|dap.Message

---@class dap.Message
---@field id number
---@field format string
---@field variables nil|table
---@field showUser nil|boolean


---@class dap.StackFrame
---@field id number
---@field name string
---@field source dap.Source|nil
---@field line number
---@field column number
---@field endLine nil|number
---@field endColumn nil|number
---@field canRestart boolean|nil
---@field presentationHint nil|"normal"|"label"|"subtle";


---@class dap.Source
---@field name nil|string
---@field path nil|string
---@field sourceReference nil|number
---@field presentationHint nil|"normal"|"emphasize"|"deemphasize"
---@field origin nil|string
---@field sources nil|dap.Source[]
---@field adapterData nil|any


---@class dap.Capabilities
---@field supportsConfigurationDoneRequest boolean|nil
---@field supportsFunctionBreakpoints boolean|nil
---@field supportsConditionalBreakpoints boolean|nil
---@field supportsHitConditionalBreakpoints boolean|nil
---@field supportsEvaluateForHovers boolean|nil
---@field exceptionBreakpointFilters dap.ExceptionBreakpointsFilter[]|nil
---@field supportsStepBack boolean|nil
---@field supportsSetVariable boolean|nil
---@field supportsRestartFrame boolean|nil
---@field supportsGotoTargetsRequest boolean|nil
---@field supportsStepInTargetsRequest boolean|nil
---@field supportsCompletionsRequest boolean|nil
---@field completionTriggerCharacters string[]|nil
---@field supportsModulesRequest boolean|nil
---@field additionalModuleColumns dap.ColumnDescriptor[]|nil
---@field supportedChecksumAlgorithms dap.ChecksumAlgorithm[]|nil
---@field supportsRestartRequest boolean|nil
---@field supportsExceptionOptions boolean|nil
---@field supportsValueFormattingOptions boolean|nil
---@field supportsExceptionInfoRequest boolean|nil
---@field supportTerminateDebuggee boolean|nil
---@field supportSuspendDebuggee boolean|nil
---@field supportsDelayedStackTraceLoading boolean|nil
---@field supportsLoadedSourcesRequest boolean|nil
---@field supportsLogPoints boolean|nil
---@field supportsTerminateThreadsRequest boolean|nil
---@field supportsSetExpression boolean|nil
---@field supportsTerminateRequest boolean|nil
---@field supportsDataBreakpoints boolean|nil
---@field supportsReadMemoryRequest boolean|nil
---@field supportsWriteMemoryRequest boolean|nil
---@field supportsDisassembleRequest boolean|nil
---@field supportsCancelRequest boolean|nil
---@field supportsBreakpointLocationsRequest boolean|nil
---@field supportsClipboardContext boolean|nil
---@field supportsSteppingGranularity boolean|nil
---@field supportsInstructionBreakpoints boolean|nil
---@field supportsExceptionFilterOptions boolean|nil
---@field supportsSingleThreadExecutionRequests boolean|nil


---@class dap.ExceptionBreakpointsFilter
---@field filter string
---@field label string
---@field description string|nil
---@field default boolean|nil
---@field supportsCondition boolean|nil
---@field conditionDescription string|nil

---@class dap.ColumnDescriptor
---@field attributeName string
---@field label string
---@field format string|nil
---@field type nil|"string"|"number"|"number"|"unixTimestampUTC"
---@field width number|nil


---@class dap.ChecksumAlgorithm
---@field algorithm "MD5"|"SHA1"|"SHA256"|"timestamp"
---@field checksum string

---@class dap.StoppedEvent
---@field reason "step"|"breakpoint"|"exception"|"pause"|"entry"|"goto"|"function breakpoint"|"data breakpoint"|"instruction breakpoint"|string;
---@field description nil|string
---@field threadId nil|number
---@field preserveFocusHint nil|boolean
---@field text nil|string
---@field allThreadsStopped nil|boolean
---@field hitBreakpointIds nil|number[]

---@class dap.TerminatedEvent
---@field restart? any


---@class dap.ProgressStartEvent
---@field progressId string
---@field title string
---@field requestId? number
---@field cancellable? boolean
---@field message? string
---@field percentage? number

---@class dap.ProgressUpdateEvent
---@field progressId string
---@field message? string
---@field percentage? number

---@class dap.ProgressEndEvent
---@field progressId string
---@field message? string


---@class dap.StartDebuggingRequestArguments
---@field configuration table<string, any>
---@field request 'launch'|'attach'
