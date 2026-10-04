/*
 * Redmine Context Menu Actions plugin.
 *
 * Opens the dialogs in core's #ajax-modal, keeps what the user typed until the
 * server confirms it, and updates the issue list in place: no page reload, no
 * lost scroll position, no lost selection.
 */
(function($, window, document) {
  'use strict';

  if (window.RedmineContextMenuActions) { return; }

  var NS = '.cma';
  var MODAL = '#ajax-modal';
  var state = null;
  var opener = null;
  var noticeTimer = null;
  var dialogCounter = 0;
  var pendingOpen = null;

  function modal() { return $(MODAL); }

  function escapeHtml(text) {
    return $('<div>').text(text == null ? '' : String(text)).html();
  }

  // Core repeats id="issue-<id>" when an issue is listed twice (My page), so
  // rows are found by attribute, never by #id.
  function issueRows(id) {
    return $('tr.hascontextmenu[id="issue-' + parseInt(id, 10) + '"]');
  }

  // The block rows core renders right after an issue row (description, last
  // notes, full width custom fields). They carry no issue id.
  function blockRows($issueRow) {
    var rows = [];
    var $next = $issueRow.next('tr');
    while ($next.length && !$next.hasClass('hascontextmenu') && !$next.hasClass('group')) {
      if ($next.children('td.block_column').length) { rows.push($next[0]); }
      $next = $next.next('tr');
    }
    return $(rows);
  }

  function lastNotesCell($issueRow) {
    return blockRows($issueRow).children('td.last_notes').first();
  }

  // Capture phase: rails-ujs stops every other click listener of a remote link
  // (stopImmediatePropagation), so a bubbling handler would never run. That
  // includes core's own handler that hides the context menu after a click, so
  // the menu is hidden here.
  function rememberOpener(event) {
    var target = event.target;
    var link = target && target.closest ? target.closest('a.cma-open') : null;
    if (!link) { return; }
    opener = link;
    if ($(link).closest('#context-menu').length && typeof window.contextMenuHide === 'function') {
      window.contextMenuHide();
    }
  }

  // Focus without scrolling: the page stays where the user left it.
  function focusQuietly(element) {
    if (!element || typeof element.focus !== 'function') { return; }
    try {
      element.focus({preventScroll: true});
    } catch (e) {
      element.focus();
    }
  }

  // Where focus goes back to when the dialog closes, resolved at that moment:
  // the link that opened it when it is still on the page; the new link of the
  // same issue when a save replaced its Last notes cell; otherwise the actions
  // button of the first issue row.
  function returnFocusTarget(origin, ids) {
    if (origin && $.contains(document.documentElement, origin) && $(origin).is(':visible')) {
      return origin;
    }
    var $row = issueRows(ids[0]).first();
    if (origin && $(origin).hasClass('cma-last-notes-link')) {
      var $link = lastNotesCell($row).children('a.cma-last-notes-link').first();
      if ($link.length) { return $link[0]; }
    }
    var $target = $row.find('a.js-contextmenu, input[type=checkbox]').first();
    return $target.length ? $target[0] : null;
  }

  function formIds($form) {
    return $form.find('.cma-ids input[name="ids[]"]').map(function() { return this.value; }).get();
  }

  function setUsersSource(url) {
    var sources = window.rm && rm.AutoComplete && rm.AutoComplete.dataSources;
    if (!sources) { return; }
    if (url) { sources.users = url; } else { delete sources.users; }
  }

  function showErrors($form, html) {
    $form.find('.cma-errors').html(html || '');
  }

  // No answer or a server error leaves the outcome unknown; the message says a
  // second submit is safe, which the server makes true.
  function showRequestError($form, status) {
    // attr, not data: jQuery would turn data-cma-error-403 into "cmaError-403".
    var known = (status === 401 || status === 403 || status === 404 || status === 422);
    var message = (known && $form.attr('data-cma-error-' + status)) || $form.attr('data-cma-error-other');
    showErrors($form, '<div id="errorExplanation"><ul><li>' + escapeHtml(message) + '</li></ul></div>');
    focusField($form);
  }

  // Core's Ctrl+Enter handler blurs the textarea before it submits. When the
  // dialog stays open, the cursor goes back where the user was typing, so they
  // can correct, retry or press Escape.
  function focusField($form) {
    focusQuietly($form.find('textarea:visible, input[type=date]:visible').first()[0]);
  }

  function refreshSubmit() {
    if (!state) { return; }
    var $form = state.form;
    $form.find('.cma-submit').prop('disabled', state.busy || !state.hasChanges());
  }

  function notice(message, kind) {
    if (!message) { return; }
    var $notice = $('#cma-notice');
    if (!$notice.length) {
      $notice = $('<div id="cma-notice" role="status" aria-live="polite"></div>').appendTo('body');
    }
    $notice.attr('class', 'flash ' + (kind === 'error' ? 'error' : 'notice'));
    $notice.text(message).stop(true, true).show();
    window.clearTimeout(noticeTimer);
    noticeTimer = window.setTimeout(function() { $notice.fadeOut(400); }, 3000);
  }

  function highlight($rows) {
    $rows.removeClass('cma-updated');
    // Reflow, so the animation restarts on a row updated twice in a row.
    $rows.each(function() { return this.offsetWidth; });
    $rows.addClass('cma-updated');
    window.setTimeout(function() { $rows.removeClass('cma-updated'); }, 2100);
  }

  function lastNotesContent(layout, html) {
    var caption = layout && layout.caption ? '<span>' + escapeHtml(layout.caption) + '</span>' : '';
    return caption + html;
  }

  // Puts the new Last notes block row where core would have rendered it: after
  // the block rows that precede it in the list's column order.
  function insertLastNotesRow($issueRow, layout, html) {
    var order = layout.order || [];
    var position = order.indexOf('last_notes');
    var $anchor = $issueRow;
    blockRows($issueRow).each(function() {
      var $td = $(this).children('td.block_column').first();
      var index = -1;
      for (var i = 0; i < order.length; i++) {
        if ($td.hasClass(order[i])) { index = i; break; }
      }
      if (index !== -1 && index < position) { $anchor = $(this); }
    });
    var $row = $('<tr></tr>').addClass($issueRow.hasClass('even') ? 'even' : 'odd');
    var $td = $('<td></td>')
      .attr('colspan', $issueRow.children('td').length)
      .addClass('last_notes block_column')
      .html(lastNotesContent(layout, html));
    $row.append($td);
    $anchor.after($row);
    // In a collapsed group the issue row is hidden; core's toggleRowGroup flips
    // every row of the group, so the new row has to start the same way.
    if (!$issueRow.is(':visible')) { $row.hide(); }
    return $row;
  }

  // Replaces the Last notes cell of every row of a saved issue on the page. A
  // missing row is only added in the list the action came from (table), the one
  // whose columns the layout describes: My page shows several lists.
  function updateLastNotes(saved, layout, table) {
    var $updated = $();
    $.each(saved || [], function(_, item) {
      issueRows(item.id).each(function() {
        var $issueRow = $(this);
        $updated = $updated.add($issueRow);
        if (!item.html) { return; }
        var $cell = lastNotesCell($issueRow);
        if ($cell.length) {
          // Without the list's layout, keep the caption core rendered, if any.
          var $caption = $cell.children('span').first();
          var content = layout ? lastNotesContent(layout, item.html)
                               : ($caption.length ? $caption[0].outerHTML : '') + item.html;
          $cell.html(content);
          $updated = $updated.add($cell.parent());
        } else if (layout && table && $issueRow.closest('table')[0] === table) {
          $updated = $updated.add(insertLastNotesRow($issueRow, layout, item.html));
        }
      });
    });
    highlight($updated);
    applyLastNotesLinks();
  }

  // F3: an "Add a note" link in each Last notes cell of the issue list, for the
  // issues the server listed as allowing notes. Idempotent, and a no-op where
  // the markup is not found; run again after a cell is replaced.
  function applyLastNotesLinks() {
    var $config = $('#cma-last-notes');
    if (!$config.length) { return; }
    var ids = $config.data('ids') || [];
    var url = $config.attr('data-url');
    var $template = $config.children('a.cma-last-notes-link').first();
    if (!url || !$template.length) { return; }
    var separator = url.indexOf('?') === -1 ? '?' : '&';

    $.each(ids, function(_, id) {
      issueRows(id).each(function() {
        var $cell = lastNotesCell($(this));
        if (!$cell.length || $cell.children('a.cma-last-notes-link').length) { return; }
        $template.clone()
          .attr('href', url + separator + encodeURIComponent('ids[]') + '=' + parseInt(id, 10))
          .prependTo($cell);
      });
    });
  }

  // A close the plugin itself asks for (after a save, or for the next dialog)
  // never asks the user.
  function closeDialog() {
    var $m = modal();
    if (state) { state.allowClose = true; }
    if ($m.hasClass('ui-dialog-content')) { $m.dialog('close'); }
  }

  function cleanup() {
    var $m = modal();
    var current = state;
    state = null;
    $m.off(NS).removeClass('cma-modal');
    $('body').removeClass('cma-dialog-open');
    if ($m.hasClass('ui-dialog-content')) { $m.dialog('option', 'appendTo', 'body'); }
    if (!current) { return; }
    setUsersSource(current.previousUsersSource);
    $m.empty();
    if (current.needsReload) {
      RedmineContextMenuActions.reload();
      return;
    }
    focusQuietly(returnFocusTarget(current.opener, current.ids));
  }

  function bindForm($m, $form, options) {
    $form.on('input' + NS + ' change' + NS, refreshSubmit);

    $form.on('submit' + NS, function(event) {
      // One request at a time: the button is off while one runs, and so is
      // any other way to submit.
      if (state && state.busy) {
        event.preventDefault();
        event.stopImmediatePropagation();
        return false;
      }
      if (state && state.prepare) { state.prepare(); }
      if (state && state.validate) {
        var error = state.validate();
        if (error) {
          event.preventDefault();
          event.stopImmediatePropagation();
          showErrors($form, '<div id="errorExplanation"><ul><li>' + escapeHtml(error) + '</li></ul></div>');
          return false;
        }
      }
      return true;
    });

    $form.on('ajax:send' + NS, function() {
      if (!state) { return; }
      state.busy = true;
      refreshSubmit();
    });
    $form.on('ajax:error' + NS, function(event, xhr, status) {
      // rails-ujs passes [response, status, xhr] in event.detail; jquery-ujs
      // passes (xhr, status) as arguments.
      var detail = event.detail || (event.originalEvent && event.originalEvent.detail);
      var request = (detail && detail[2]) || xhr;
      showRequestError($form, request ? request.status : 0);
    });
    $form.on('ajax:complete' + NS, function() {
      if (!state) { return; }
      state.busy = false;
      // After rails-ujs has re-enabled the button it disabled on submit.
      window.setTimeout(refreshSubmit, 0);
    });

    // The x button and Cancel ask before something typed is lost; Esc closes at
    // once. The question follows the user's Redmine preference "Warn me when
    // leaving a page with unsaved text": without it the form has no message.
    $m.on('dialogbeforeclose' + NS, function(event) {
      if (!state || state.allowClose || !state.hasChanges()) { return true; }
      var source = event.originalEvent;
      if (source && source.type === 'keydown') { return true; }
      var message = $form.attr('data-cma-leave');
      return !message || window.confirm(message);
    });
    $m.on('dialogclose' + NS, cleanup);

    if (options.bind) { options.bind(); }
  }

  // F2: the Dates dialog. Empty means "no change", Clear removes the date, as in
  // core's bulk edit.
  function datesOptions($form) {
    var $dates = $form.find('input.cma-date');
    return {
      reloadOnSuccess: true,
      // A prefilled date the user emptied is meant to go: it is sent as Clear,
      // and the Clear box shows it, rather than read as "no change".
      prepare: function() {
        $dates.each(function() {
          if (!this.disabled && this.value === '' && String($(this).attr('data-initial') || '') !== '') {
            $('#' + this.id + '_clear').prop('checked', true);
            this.disabled = true;
          }
        });
      },
      hasChanges: function() {
        var changed = false;
        $dates.each(function() {
          if (!this.disabled && this.value !== String($(this).attr('data-initial') || '')) { changed = true; }
        });
        if ($form.find('input[type=checkbox][value=none]:checked').length) { changed = true; }
        if ($.trim($form.find('textarea').val() || '') !== '') { changed = true; }
        return changed;
      },
      validate: function() {
        var start = $form.find('input.cma-start-date:enabled').val();
        var due = $form.find('input.cma-due-date:enabled').val();
        // ISO dates compare as strings.
        if (start && due && start > due) { return $form.attr('data-cma-date-order'); }
        return null;
      },
      bind: function() {
        // Core binds data-disables inside #content. The dialog is attached there
        // while it is open, but binding it here keeps Clear working when it
        // cannot be; both set the same state.
        $form.on('change' + NS, 'input[data-disables]', function() {
          $($(this).attr('data-disables')).prop('disabled', this.checked);
          refreshSubmit();
        });
        // The collapsed note opens with the keyboard too.
        $form.on('keydown' + NS, 'fieldset.collapsible > legend', function(event) {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            window.toggleFieldset(this);
            $(this).closest('fieldset').find('textarea:visible').first().trigger('focus');
          }
        });
      }
    };
  }

  var RedmineContextMenuActions = {
    // Called by the JavaScript response of the new_note and edit_dates actions.
    openDialog: function(options) {
      var $m = modal();
      if (!$m.length || typeof window.showModal !== 'function') { return; }
      if (state) { closeDialog(); }
      pendingOpen = null;

      $m.html(options.html);
      var $form = $m.find('form.cma-form').first();
      if (options.dates) { options = $.extend({}, options, datesOptions($form)); }
      var ids = formIds($form);
      var users = window.rm && rm.AutoComplete && rm.AutoComplete.dataSources;
      // The response names the dialog it answers; a late answer to a closed
      // dialog must not touch the one open now.
      var token = 'd' + (++dialogCounter) + '-' + new Date().getTime().toString(36);
      $('<input type="hidden" name="cma_dialog">').val(token).appendTo($form);
      // The list the action came from: the one a missing Last notes row goes in.
      var $origin = opener ? $(opener).closest('table.list') : $();
      if (!$origin.length) { $origin = $('tr.hascontextmenu.context-menu-selection').first().closest('table.list'); }

      state = {
        token: token,
        table: $origin[0] || null,
        form: $form,
        busy: false,
        allowClose: false,
        needsReload: false,
        reloadOnSuccess: !!options.reloadOnSuccess,
        opener: opener,
        ids: ids,
        previousUsersSource: users ? users.users : undefined,
        hasChanges: options.hasChanges || function() {
          return $.trim($form.find('textarea').val() || '') !== '';
        },
        validate: options.validate || null,
        prepare: options.prepare || null
      };
      setUsersSource(options.mentions);
      $m.addClass('cma-modal');

      // The wiki toolbar and the date picker need core scripts that only pages
      // with a context menu load. Without them the dialog still works, as a
      // plain textarea and a native date field.
      if (options.toolbar && typeof window.jsToolBar === 'function') {
        $m.append(options.toolbar);
      }
      if (typeof window.datepickerOptions !== 'undefined' && $.fn.datepickerFallback) {
        $form.find('input[type=date]').each(function() {
          $(this).addClass('date').datepickerFallback(window.datepickerOptions);
        });
      }

      bindForm($m, $form, options);
      window.showModal('ajax-modal', options.width || '720px');
      // Core styles the wiki toolbar tabs, and delegates its preview, inside
      // #content only, and a dialog lives in <body>. Attached to #content, the
      // toolbar looks and works as on the issue page. cleanup() gives the dialog
      // back to <body> for core's own modals. Re-applying the position option
      // core's dialog already has (centred, kept on screen) places it again.
      var $content = $('#content');
      if ($content.length && $m.hasClass('ui-dialog-content')) {
        $m.dialog('option', 'appendTo', $content);
        $m.dialog('option', 'position', $m.dialog('option', 'position'));
      }
      $('body').addClass('cma-dialog-open');
      refreshSubmit();
      if (options.focus) { focusQuietly($form.find(options.focus)[0]); }
    },

    // Called by the JavaScript response of a submit, with the outcome per issue.
    saved: function(data) {
      var mine = !!state && (!data.dialog || data.dialog === state.token);
      updateLastNotes(data.saved, data.lastNotes, mine ? state.table : null);
      var savedAny = data.saved && data.saved.length > 0;

      if (!mine) {
        // The answer to a dialog closed while its request ran. The rows are
        // updated; the dialog open now, if any, is left alone. A reload waits
        // until that dialog closes, so nothing typed there is lost.
        if (savedAny && data.reload) {
          RedmineContextMenuActions.rememberNotice(data.notice);
          if (state) { state.needsReload = true; } else { RedmineContextMenuActions.reload(); }
        } else if (data.failed && data.failed.length) {
          notice(data.errorText, 'error');
        } else if (savedAny) {
          notice(data.notice);
        }
        return;
      }
      var $form = state.form;
      if (savedAny && (state.reloadOnSuccess || data.reload)) { state.needsReload = true; }

      if (!data.failed || data.failed.length === 0) {
        if (!savedAny) {
          // Nothing was asked to change: nothing to confirm or reload.
          closeDialog();
          return;
        }
        if (state.needsReload) {
          // cleanup() reloads; the notice is shown once the page is back.
          RedmineContextMenuActions.rememberNotice(data.notice);
          closeDialog();
        } else {
          closeDialog();
          notice(data.notice);
        }
        return;
      }

      // Partial or no success: the text stays, the errors show, and the form now
      // targets only the issues that did not save, so a retry never adds a
      // second note to one that did.
      showErrors($form, data.errorsHtml);
      focusField($form);
      if (savedAny) {
        $form.find('.cma-ids').replaceWith(data.idsHtml);
        $form.find('.cma-issues-summary').replaceWith(data.summaryHtml);
      }
      refreshSubmit();
    },

    // Reloads the page and comes back to the same scroll position, for changes
    // that move rows around (dates affect sorting, filters and overdue styling).
    reload: function() {
      try {
        window.sessionStorage.setItem('cma-scroll', JSON.stringify({path: window.location.href, y: window.scrollY}));
      } catch (e) { /* private mode: the browser keeps its own position */ }
      window.location.reload();
    },

    rememberNotice: function(message) {
      try { window.sessionStorage.setItem('cma-notice', message); } catch (e) { /* see reload */ }
    },

    restoreAfterReload: function() {
      var saved;
      var message;
      try {
        saved = JSON.parse(window.sessionStorage.getItem('cma-scroll') || 'null');
        message = window.sessionStorage.getItem('cma-notice');
        window.sessionStorage.removeItem('cma-scroll');
        window.sessionStorage.removeItem('cma-notice');
      } catch (e) { return; }
      if (saved && saved.path === window.location.href) { window.scrollTo(0, saved.y); }
      if (message) { notice(message); }
    },

    applyLastNotesLinks: applyLastNotesLinks,
    notice: notice,
    issueRows: issueRows,
    lastNotesCell: lastNotesCell
  };

  window.RedmineContextMenuActions = RedmineContextMenuActions;

  document.addEventListener('click', rememberOpener, true);

  // Only the dialog asked for last opens: an older request still on its way
  // (a slow answer) is aborted, so it cannot replace a dialog opened after it.
  $(document).on('ajax:beforeSend', 'a.cma-open', function(event, xhrArgument) {
    var detail = event.detail || (event.originalEvent && event.originalEvent.detail);
    var xhr = (detail && detail[0]) || xhrArgument;
    if (pendingOpen && pendingOpen !== xhr && pendingOpen.readyState !== 4) { pendingOpen.abort(); }
    pendingOpen = xhr || null;
  });

  // Leaving the page asks too, while a dialog holds something not saved, with
  // the same preference and text as core's warning on the issue page.
  window.addEventListener('beforeunload', function(event) {
    if (!state || !state.hasChanges()) { return undefined; }
    var message = state.form.attr('data-cma-leave');
    if (!message) { return undefined; }
    event.preventDefault();
    event.returnValue = message;
    return message;
  });
  $(function() {
    applyLastNotesLinks();
    RedmineContextMenuActions.restoreAfterReload();
  });
})(jQuery, window, document);
