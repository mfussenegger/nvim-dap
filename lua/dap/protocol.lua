---@meta


---@class dap.ProtocolMessage
---@field seq number
---@field type "request"|"response"|"event"|string


---@class dap.Request: dap.ProtocolMessage
---@field type "request"
---@field command string
---@field arguments? any


---@class dap.Event: dap.ProtocolMessage
---@field type "event"
---@field event string
---@field body? any


---@class dap.Response: dap.ProtocolMessage
---@field type "response"
---@field request_seq number
---@field success boolean
---@field command string
---@field message? "cancelled"|"notStopped"|string
---@field body? any


---@class dap.ErrorResponse: dap.Response
---@field message string
---@field body {error?: dap.Message}


---@class dap.Message
---@field id number
---@field format string
---@field variables nil|table
---@field showUser nil|boolean


---@class dap.Thread
---@field id number
---@field name string
---@field frames nil|dap.StackFrame[] not part of the spec; added by nvim-dap
---@field stopped nil|boolean not part of the spec; added by nvim-dap


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
---@field scopes? dap.Scope[] Not part of spec; added by nvim-dap


---@class dap.Scope
---@field name string
---@field presentationHint? "arguments"|"locals"|"registers"|string
---@field variablesReference number
---@field namedVariables? number
---@field indexedVariables? number
---@field expensive boolean
---@field source? dap.Source
---@field line? number
---@field column? number
---@field endLine? number
---@field endColumn? number
---@field variables? table<string, dap.Variable> by variable name. Not part of spec


---@class dap.Variable
---@field name string
---@field value string
---@field type? string
---@field presentationHint? dap.VariablePresentationHint
---@field evaluateName? string
---@field variablesReference number
---@field namedVariables? number
---@field indexedVariables? number
---@field memoryReference? string


---@class dap.VariablePresentationHint
---@field kind?
---|'property'
---|'method'
---|'class'
---|'data'
---|'event'
---|'baseClass'
---|'innerClass'
---|'interface'
---|'mostDerivedClass'
---|'virtual'
---|'dataBreakpoint'
---|string;
---@field attributes? ('static'|'constant'|'readOnly'|'rawString'|'hasObjectId'|'canHaveObjectId'|'hasSideEffects'|'hasDataBreakpoint'|string)[]
---@field visibility?
---|'public'
---|'private'
---|'protected'
---|'internal'
---|'final'
---|string
---@field lazy? boolean


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


---@class dap.Breakpoint
---@field id? number
---@field verified boolean
---@field message? string
---@field source? dap.Source
---@field line? number
---@field column? number
---@field endLine? number
---@field endColumn? number
---@field instructionReference? string
---@field offset? number


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


---@class dap.ThreadEvent
---@field reason "started"|"exited"|string
---@field threadId number


---@class dap.ContinuedEvent
---@field threadId number
---@field allThreadsContinued? boolean


---@class dap.BreakpointEvent
---@field reason "changed"|"new"|"removed"|string
---@field breakpoint dap.Breakpoint


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
