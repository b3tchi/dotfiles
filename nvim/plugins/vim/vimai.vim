Plug 'madox2/vim-ai', { 'do': './install.sh' }

function LoadedVimAI()
" This prompt instructs model to work with syntax highlighting
let s:initial_chat_prompt =<< trim END
>>> system

You are a general assistant.
If you attach a code block add syntax type after ``` to enable syntax highlighting.
END

let g:vim_ai_chat = {

\  "options": {
\    "model": "gpt-4",
\    "max_tokens": 1000,
\    "temperature": 1,
\    "request_timeout": 20,
\    "initial_prompt": s:initial_chat_prompt,
\  },
\  "ui": {
\    "code_syntax_enabled": 1,
\    "populate_options": 0,
\    "open_chat_command": "below new | call vim_ai#MakeScratchWindow()",
\  },
\}

endfunction

augroup LoadedVimAI
  autocmd!
  autocmd User PlugLoaded call LoadedVimAI()
augroup END
