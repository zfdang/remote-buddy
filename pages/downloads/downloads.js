(function () {
  var english = document.documentElement.lang === 'en';
  var tagBadge = document.getElementById('release-tag');
  var statusNote = document.getElementById('mirror-status');
  var cardsContainer = document.getElementById('mirror-cards');
  var fallbackPanel = document.getElementById('mirror-fallback');

  if (!cardsContainer) return;

  function formatBytes(bytes) {
    if (!bytes || typeof bytes !== 'number') return '';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function renderPackages(manifest, websiteBaseUrl) {
    var tag = manifest && manifest.tag;
    var packages = manifest && manifest.packages;
    if (!tag || !packages || !packages.arm64 || !packages.intel) {
      throw new Error('Incomplete download manifest');
    }

    if (tagBadge) {
      tagBadge.textContent = (english ? 'Latest version: ' : '最新版本：') + tag;
      tagBadge.hidden = false;
    }

    var specs = [
      {
        key: 'arm64',
        title: english ? 'Mac with Apple Silicon' : 'Apple Silicon 芯片 Mac',
        subtitle: english
          ? 'For M1 / M2 / M3 / M4 and newer Apple Silicon Macs. Includes the app and virtual microphone driver.'
          : '适用于 M1 / M2 / M3 / M4 及更新款芯片 Mac，包含应用与虚拟麦克风驱动。',
        archLabel: 'arm64 · .pkg',
        recommended: true,
        badge: english ? 'M1–M4 · Recommended' : 'M1–M4 主流机型'
      },
      {
        key: 'intel',
        title: english ? 'Mac with Intel Processor' : 'Intel 处理器 Mac',
        subtitle: english
          ? 'For Intel-based Macs running macOS 14 or later. Includes the app and virtual microphone driver.'
          : '适用于运行 macOS 14 及以上的 Intel 芯片 Mac，包含应用与虚拟麦克风驱动。',
        archLabel: 'x86_64 · .pkg'
      }
    ];

    if (packages.uninstaller && packages.uninstaller.name) {
      specs.push({
        key: 'uninstaller',
        title: english ? 'Universal Uninstaller' : '通用卸载安装包',
        subtitle: english
          ? 'Removes the app, virtual microphone driver, and optionally preferences/logs on Apple Silicon & Intel.'
          : '一键移除 App、虚拟麦克风驱动，并可选择清理设置与日志（Apple Silicon / Intel 通用）。',
        archLabel: 'universal · .pkg',
        wide: true,
        isUninstaller: true
      });
    }

    cardsContainer.innerHTML = '';
    specs.forEach(function (spec) {
      var pkg = packages[spec.key];
      if (!pkg || !pkg.name) return;

      var card = document.createElement('article');
      card.className = 'download-card' +
        (spec.recommended ? ' is-recommended' : '') +
        (spec.wide ? ' is-wide' : '');

      var sizeText = formatBytes(pkg.size);
      var websiteHref = (websiteBaseUrl || '') + encodeURIComponent(pkg.name);
      var badgeHtml = spec.badge ? '<span class="download-badge">' + spec.badge + '</span>' : '';
      var primaryBtnClass = spec.isUninstaller ? 'button secondary' : 'button primary';

      card.innerHTML =
        '<div class="download-card-body">' +
          '<h2>' + spec.title + badgeHtml + '</h2>' +
          '<p>' + spec.subtitle + '</p>' +
          '<div class="download-meta">' +
            '<span><code>' + pkg.name + '</code></span>' +
            (sizeText ? '<span>' + sizeText + '</span>' : '') +
            '<span>' + spec.archLabel + '</span>' +
          '</div>' +
        '</div>' +
        '<div class="download-actions">' +
          '<a class="' + primaryBtnClass + '" href="' + websiteHref + '" download>' +
            (english ? 'Download from Website ↓' : '从官网下载 ↓') +
          '</a>' +
          '<a class="button secondary" href="https://github.com/zfdang/remote-buddy/releases/download/' +
            encodeURIComponent(tag) + '/' + encodeURIComponent(pkg.name) + '">' +
            (english ? 'Download from GitHub ↗' : '从 GitHub 下载 ↗') +
          '</a>' +
        '</div>';

      cardsContainer.appendChild(card);
    });

    if (fallbackPanel) fallbackPanel.hidden = true;
    if (statusNote) {
      statusNote.hidden = true;
    }
  }

  function loadManifest(url) {
    return fetch(url, { cache: 'no-store' }).then(function (response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.json();
    });
  }

  loadManifest('latest.json')
    .then(function (manifest) {
      renderPackages(manifest, '');
    })
    .catch(function () {
      return loadManifest('https://remote.zfdang.com/downloads/latest.json')
        .then(function (manifest) {
          renderPackages(manifest, 'https://remote.zfdang.com/downloads/');
        });
    })
    .catch(function () {
      if (fallbackPanel) fallbackPanel.hidden = false;
      if (statusNote) statusNote.hidden = true;
    });
})();
