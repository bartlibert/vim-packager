let s:packager = {}
let s:defaults = {
      \ 'dir': printf('%s/%s', split(&packpath, ',')[0], 'pack/packager'),
      \ 'depth': 5
      \ }

function! packager#new(opts) abort
  return s:packager.new(a:opts)
endfunction

function! s:packager.new(opts) abort
  let l:instance = extend(copy(self), extend(copy(a:opts), s:defaults, 'keep'))
  if has_key(a:opts, 'dir')
    let l:instance.dir = substitute(fnamemodify(a:opts.dir, ':p'), '\/$', '', '')
  endif
  let l:instance.plugins = []
  let l:instance.remaining_jobs = 0
  silent! call mkdir(printf('%s/%s', l:instance.dir, 'opt'), 'p')
  silent! call mkdir(printf('%s/%s', l:instance.dir, 'start'), 'p')
  return l:instance
endfunction

function! s:packager.add(name, opts) abort
  let l:plugin = packager#plugin#new(a:name, a:opts, self.dir)
  if len(filter(copy(self.plugins), printf('v:val.name ==? "%s"', l:plugin.name))) > 0
    return
  endif
  return add(self.plugins, l:plugin)
endfunction

function! s:packager.install(opts) abort
  let self.result = []
  let self.remaining_jobs = len(self.plugins)
  let self.install_opts = a:opts
  call self.open_buffer()
  call self.update_top_status()
  for l:plugin in self.plugins
    call self.start_job(l:plugin.git_command(self.depth), 's:stdout_handler', l:plugin)
  endfor
endfunction

function! s:packager.clean() abort
  let l:folders = glob(printf('%s/*/*', self.dir), 0, 1)
  let l:plugins = map(copy(self.plugins), 'v:val.dir')
  function! s:clean_filter(plugins, key, val)
    return index(a:plugins, a:val) < 0
  endfunction

  let l:to_clean = filter(copy(l:folders), function('s:clean_filter', [l:plugins]))

  if len(l:to_clean) <=? 0
    echo 'Already clean.'
    return 0
  endif

  call self.open_buffer()
  call setline(1, 'Clean up.')
  call setline(2, '')

  for l:item in l:to_clean
    call append(2, packager#utils#status_progress(l:item, 'Waiting for confirmation...'))
  endfor

  if !packager#utils#confirm('Remove above folder(s)?')
    return self.quit()
  endif

  for l:item in l:to_clean
    let l:line = search(printf('^+\s%s', l:item), 'n')
    if delete(l:item, 'rf') !=? 0
      call setline(l:line, packager#utils#status_error(l:item, 'Failed.'))
    else
      call setline(l:line, packager#utils#status_ok(l:item, 'Removed!'))
    endif
  endfor
endfunction

function! s:packager.status() abort
  let l:result = []

  for l:plugin in self.plugins
    if !l:plugin.installed
      call add(l:result, packager#utils#status_error(l:plugin.name, 'Not installed.'))
      continue
    endif
    if empty(l:plugin.last_update)
      call add(l:result, packager#utils#status_ok(l:plugin.name, 'OK.'))
      continue
    endif

    call add(l:result, packager#utils#status_ok(l:plugin.name, 'Updated.'))
    for l:update in l:plugin.last_update
      call add(l:result, printf('  * %s', l:update))
    endfor
  endfor

  call self.open_buffer()
  call setline(1, 'Plugin status.')
  call setline(2, '')
  call append(2, l:result)
  set nomodifiable
endfunction

function! s:packager.quit()
  if self.remaining_jobs > 0
    if !packager#utils#confirm('Installation is in progress. Are you sure you want to quit?')
      return
    endif
  endif
  silent exe ':q!'
endfunction

function! s:packager.update_top_status() abort
  let l:total = len(self.plugins)
  let l:installed = l:total - self.remaining_jobs
  let l:finished = self.remaining_jobs > 0 ? '' : ' - Finished!'
  call setline(1, printf('Installed plugins %d / %d%s', l:installed, l:total, l:finished))
  return setline(2, '')
endfunction

function! s:packager.update_top_status_installed() abort
  let self.remaining_jobs -= 1
  let self.remaining_jobs = max([0, self.remaining_jobs]) "Make sure it's not negative
  return self.update_top_status()
endfunction

function! s:packager.post_update_hooks() abort
  if has_key(self, 'post_update_hook_called')
    return
  endif

  let self.post_update_hook_called = 1

  if getbufvar(bufname('%'), '&filetype') ==? 'packager'
    setlocal nomodifiable
  endif

  call self.update_remote_plugins_and_helptags()

  if has_key(self, 'install_opts') && has_key(self.install_opts, 'on_finish')
    silent! exe 'redraw'
    exe self.install_opts.on_finish
  endif
endfunction

function! s:packager.open_buffer() abort
  vertical topleft new
  setf packager
  setlocal buftype=nofile bufhidden=wipe nobuflisted nolist noswapfile nowrap cursorline nospell
  syntax clear
  syn match packagerCheck /^✓/
  syn match packagerPlus /^+/
  syn match packagerX /^✗/
  syn match packagerStar /^\s\s\*/
  syn match packagerStatus /\(^+.*—\)\@<=\s.*$/
  syn match packagerStatusSuccess /\(^✓.*—\)\@<=\s.*$/
  syn match packagerStatusError /\(^✗.*—\)\@<=\s.*$/
  syn match packagerStatusCommit /\(^\*.*—\)\@<=\s.*$/
  syn match packagerSha /\(\*\s\)\@<=[0-9a-f]\{4,}/
  syn match packagerRelDate /([^)]*)$/

  hi def link packagerPlus           Special
  hi def link packagerCheck          Function
  hi def link packagerX              WarningMsg
  hi def link packagerStar           Boolean
  hi def link packagerStatus         Constant
  hi def link packagerStatusCommit   Constant
  hi def link packagerStatusSuccess  Function
  hi def link packagerStatusError    WarningMsg
  hi def link packagerSha            Identifier
  hi def link packagerRelDate        Comment
  nnoremap <silent><buffer> q :call g:packager.quit()<CR>
  nnoremap <silent><buffer> <CR> :call g:packager.open_sha()<CR>
  nnoremap <silent><buffer> <C-j> :call g:packager.goto_plugin('next')<CR>
  nnoremap <silent><buffer> <C-k> :call g:packager.goto_plugin('previous')<CR>
endfunction

function! s:packager.open_sha() abort
  let l:sha = matchstr(getline('.'), '^\s\s\*\s\zs[0-9a-f]\{7,9}')
  if empty(l:sha)
    return
  endif

  let l:plugin = self.find_plugin_by_sha(l:sha)

  if empty(l:plugin)
    return
  endif

  silent exe 'pedit' l:sha
  wincmd p
  setlocal previewwindow filetype=git buftype=nofile nobuflisted modifiable
  let l:sha_content = packager#utils#system(['git', '-C', l:plugin.dir, 'show',
        \ '--no-color', '--pretty=medium', l:sha
        \ ])

  call append(1, l:sha_content)
  1delete _
  setlocal nomodifiable
  nnoremap <silent><buffer> q :q<CR>
endfunction

function! s:packager.find_plugin_by_sha(sha) abort
  for l:plugin in self.plugins
    let l:commits = filter(copy(l:plugin.last_update), printf("v:val =~? '^%s'", a:sha))
    if len(l:commits) > 0
      return l:plugin
    endif
  endfor

  return {}
endfunction

function! s:packager.goto_plugin(dir) abort
  let l:icons = join(values(packager#utils#status_icons()), '\|')
  let l:flag = a:dir ==? 'previous' ? 'b': ''
  return search(printf('^\(%s\)\s.*$', l:icons), l:flag)
endfunction

function! s:packager.update_remote_plugins_and_helptags() abort
  for l:plugin in self.plugins
    if l:plugin.updated
      silent! exe 'helptags' fnameescape(printf('%s/doc', l:plugin.dir))

      if has('nvim') && isdirectory(printf('%s/rplugin', l:plugin.dir))
        call packager#utils#add_rtp(l:plugin.dir)
        exe 'UpdateRemotePlugins'
      endif
    endif
  endfor
endfunction

function! s:packager.start_job(cmd, handler, plugin, ...) abort
  let l:opts = {
        \ 'on_stdout': function(a:handler, [a:plugin], self),
        \ 'on_stderr': function(a:handler, [a:plugin], self),
        \ 'on_exit': function(a:handler, [a:plugin], self)
        \ }

  if a:0 > 0
    let l:opts.cwd = a:1
  endif

  return packager#job#start(a:cmd, l:opts)
endfunction

function! s:hook_stdout_handler(plugin, id, message, event) dict
  if a:event !=? 'exit'
    let l:msg = get(split(a:message[0], '\r'), -1, a:message[0])
    return a:plugin.update_status('ok', l:msg)
  endif

  call self.update_top_status_installed()
  "TODO: Add better message
  if a:message !=? 0
    call a:plugin.update_status('error', printf('Error on hook - status %s', a:message))
  else
    call a:plugin.update_status('ok', 'Finished running post update hook!')
  endif

  if self.remaining_jobs <=? 0
    call self.post_update_hooks()
  endif
endfunction

function! s:stdout_handler(plugin, id, message, event) dict
  if a:event !=? 'exit'
    let l:msg = get(split(a:message[0], '\r'), -1, a:message[0])
    return a:plugin.update_status('progress', l:msg)
  endif

  if a:message !=? 0
    call self.update_top_status_installed()
    return a:plugin.update_status('error', printf('Error - status code %d', a:message))
  endif

  call a:plugin.update_install_status()

  if a:plugin.updated && !empty(a:plugin.do)
    call a:plugin.update_status('ok', 'Running post update hooks...')
    if a:plugin.do[0] ==? ':'
      try
        exe a:plugin.do[1:]
        call a:plugin.update_status('ok', 'Finished running post update hook!')
      catch
        call a:plugin.update_status('error', printf('Error on hook - %s', v:exception))
      endtry
      call self.update_top_status_installed()
    else
      call self.start_job(a:plugin.do, 's:hook_stdout_handler', a:plugin, a:plugin.dir)
    endif
  else
    call self.update_top_status_installed()
  endif

  if self.remaining_jobs <=? 0
    call self.post_update_hooks()
  endif
endfunction