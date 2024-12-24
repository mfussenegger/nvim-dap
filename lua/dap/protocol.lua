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


---@class dap.ThreadResponse
---@field threads dap.Thread[]

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


---@class dap.StackFrameFormat : dap.ValueFormat
--- Displays parameters for the stack frame.
--- @field parameters? boolean
---
--- Displays the types of parameters for the stack frame.
--- @field parameterTypes? boolean
---
--- Displays the names of parameters for the stack frame.
--- @field parameterNames? boolean
---
--- Displays the values of parameters for the stack frame.
--- @field parameterValues? boolean
---
--- Displays the line number of the stack frame.
--- @field line? boolean
---
--- Displays the module of the stack frame.
--- @field module? boolean
---
--- Includes all stack frames, including those the debug adapter might
--- otherwise hide.
--- @field includeAll? boolean


---@class dap.StackTraceArguments
---@field threadId number thread for which to retrieve the stackTrace
---@field startFrame? number index of the first frame to return. If omitted frames start at 0
---@field levels? number maximum number of frames to return. If absent or 0 all frames are returned
---@field format? dap.StackFrameFormat only honored with supportsValueFormattingOptions capability

---@class dap.StackTraceResponse
---@field stackFrames dap.StackFrame[]
---@field totalFrames? number


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


---@class dap.ScopesResponse
---@field scopes dap.Scope[]


---@class dap.ValueFormat
---@field hex? boolean Display the value in hex

---@class dap.VariablesArguments
---@field variablesReference number variable for which to retrieve its children
---@field filter? "indexed"|"named" filter to limit child variables. Both are fetched if nil
---@field start? number index of the first variable to return. If nil children start at 0. Requires `supportsVariablePaging`
---@field count? number number of variables to return. If missing or 0, all variables are returned. Requires `supportsVariablePaging`
---@field format? dap.ValueFormat

---@class dap.VariableResponse
---@field variables dap.Variable[]

---@class dap.Variable
---@field name string
---@field value string
---@field type? string
---@field presentationHint? dap.VariablePresentationHint
---@field evaluateName? string
---@field variablesReference number if > 0 the variable is structured
---@field namedVariables? number
---@field indexedVariables? number
---@field memoryReference? string
---@field declarationLocationReference? number
---@field valueLocationReference? number
---@field variables? dap.Variable[] resolved variablesReference. Not part of the spec; added by nvim-dap
---@field parent? dap.Variable|dap.Scope injected by nvim-dap

---@class dap.EvaluateArguments
---@field expression string
---@field frameId? number
---@field context? "watch"|"repl"|"hover"|"clipboard"|"variables"|string
---@field format? dap.ValueFormat

---@class dap.EvaluateResponse
---@field result string
---@field type? string
---@field presentationHint? dap.VariablePresentationHint
---@field variablesReference number
---@field namedVariables? number
---@field indexedVariables? number
---@field memoryReference? string
---@field valueLocationReference? number


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


---@class dap.SourceResponse
---@field content string
---@field mimeType? string


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

---@class dap.SetBreakpointsResponse
---@field breakpoints dap.Breakpoint[]


---@class dap.SetBreakpointsArguments
---
--- location of the breakpoint.
--- Either source.path or source.sourceReference must be specified.
---@field source dap.Source
---@field breakpoints? dap.SourceBreakpoint[]
---@field sourceModified? boolean


---@class dap.SourceBreakpoint
---@field line integer
---@field column? integer
---@field condition? string
---@field hitCondition? string
---@field logMessage? string
---@field mode? string


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

---@class dap.InitializedEvent

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

---@class dap.TerminateArguments
---@field restart? boolean

---@class dap.DisconnectArguments
---@field restart? boolean
---@field terminateDebuggee? boolean requires `supportTerminateDebuggee` capability
---@field suspendDebuggee? boolean requires `supportSuspendDebuggee` capability


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


---@class dap.OutputEvent
---@field category? "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@field output string
---@field group? "start"|"startCollapsed"|"end"
---
--- if > 0 the output contains objects which
--- can be retrieved by passing `variablesReference` to the `variables` request
--- as long as execution remains suspended.
---@field variablesReference? number
---@field source? dap.Source
---@field line? integer
---@field column? integer
---@field data? any


---@class dap.StartDebuggingRequestArguments
---@field configuration table<string, any>
---@field request 'launch'|'attach'


---@class dap.CompletionsResponse
---@field targets dap.CompletionItem[]


---@class dap.LocationsArguments
---@field locationReference number


---@class dap.LocationsResponse
---@field source dap.Source
---@field line integer
---@field column? integer
---@field endLine? integer
---@field endColumn? integer


---@alias dap.CompletionItemType
---|'method'
---|'function'
---|'constructor'
---|'field'
---|'variable'
---|'class'
---|'interface'
---|'module'
---|'property'
---|'unit'
---|'value'
---|'enum'
---|'keyword'
---|'snippet'
---|'text'
---|'color'
---|'file'
---|'reference'
---|'customcolor'

---@class dap.CompletionsArguments
---@field frameId? number
---@field text string
---@field column integer utf-16 code units, 0- or 1-based depending on columnsStartAt1
---@field line? integer

---@class dap.CompletionItem
---@field label string By default this is also the text that is inserted when selecting this completion
---@field text? string If present and not empty this is inserted instead of the label
---@field sortText? string Used to sort completion items if present and not empty. Otherwise label is used
---@field detail? string human-readable string with additional information about this item. Like type or symbol information
---@field type? dap.CompletionItemType
---@field start? number Start position in UTF-16 code units. (within the `text` attribute of the `completions` request) 0- or 1-based depending on `columnsStartAt1` capability. If omitted, the text is added at the location of the `column` attribute of the `completions` request.
---@field length? number How many characters are overwritten by the completion text. Measured in UTF-16 code units. If missing the value 0 is assumed which results in the completion text being inserted.
---@field selectionStart? number
---@field selectionLength? number


---@alias dap.SteppingGranularity 'statement'|'line'|'instruction'
