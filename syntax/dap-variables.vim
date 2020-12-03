if exists('b:current_syntax')
  finish
endif

syn match DapVariableTreeType "[a-zA-Z0-9_<>]\+$"
syn match DapVariableTreeOperator "[=:]\s"
syn match DapVariableTreeNumber "[0.9[.0-9]"
syn region DapVariableTreeString start=+"+ end=+"+ end=+$+
syn region DapVariableTreeString start=+'+ end=+'+ end=+$+

" From Python syntax
syn match   DapVariableTreeNumber	"\<0[oO]\=\o\+[Ll]\=\>"
syn match   DapVariableTreeNumber	"\<0[xX]\x\+[Ll]\=\>"
syn match   DapVariableTreeNumber	"\<0[bB][01]\+[Ll]\=\>"
syn match   DapVariableTreeNumber	"\<\%([1-9]\d*\|0\)[Ll]\=\>"
syn match   DapVariableTreeNumber	"\<\d\+[jJ]\>"
syn match   DapVariableTreeNumber	"\<\d\+[eE][+-]\=\d\+[jJ]\=\>"
syn match   DapVariableTreeNumber
\ "\<\d\+\.\%([eE][+-]\=\d\+\)\=[jJ]\=\%(\W\|$\)\@="
syn match   DapVariableTreeNumber
\ "\%(^\|\W\)\zs\d*\.\d\+\%([eE][+-]\=\d\+\)\=[jJ]\=\>"

hi def link DapVariableTreeType Comment
hi def link DapVariableTreeNumber Number
hi def link DapVariableTreeOperator Operator
hi def link DapVariableTreeString String

let b:current_syntax = 'dap-variables'
