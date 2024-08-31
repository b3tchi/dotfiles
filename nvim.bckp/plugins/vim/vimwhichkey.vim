" --- VimWhichKey ---
set timeoutlen=500
if g:vimmode != 3

  call which_key#register('<Space>', "g:which_key_map")
  nnoremap <silent><space> :WhichKey ' '<CR>
  " moved before bindigs
  " let g:which_key_use_floating_win = 1 "make as floating window
  " let g:which_key_run_map_on_popup = 1

endif

function! RecurseForPath(dict,skey)
  for key in keys(a:dict)
    if type(a:dict[key]) == type({})
      call RecurseForPath(a:dict[key],a:skey.key)
    else
      if key != 'name'
      endif
    endif
  endfor
endfunction

