// Local illustration only: no microphone, network requests or text collection.
const button = document.querySelector('#talk');
const art = document.querySelector('.hero-art');
const status = document.querySelector('#demo-status');
const english = document.documentElement.lang === 'en';
function start() { art.classList.add('is-listening'); status.textContent = english ? 'Button held · Sending audio' : '语音键按下 · 传递声音'; }
function stop() { art.classList.remove('is-listening'); status.textContent = english ? 'Button released · Over to your tool' : '语音键松开 · 交给输入工具'; }
button.addEventListener('pointerdown', event => { button.setPointerCapture(event.pointerId); start(); });
button.addEventListener('pointerup', stop);
button.addEventListener('pointercancel', stop);
button.addEventListener('lostpointercapture', stop);
button.addEventListener('keydown', event => { if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); start(); } });
button.addEventListener('keyup', event => { if (event.key === ' ' || event.key === 'Enter') stop(); });
button.addEventListener('blur', stop);

// Cathedral 3D Stage Gallery Controller
(function initCathedralGallery() {
  const stage = document.querySelector('#gallery-stage');
  const indicatorsContainer = document.querySelector('#gallery-indicators');
  const categoryBtns = document.querySelectorAll('.category-btn');
  const prevBtn = document.querySelector('.stage-prev');
  const nextBtn = document.querySelector('.stage-next');
  const captionBadge = document.querySelector('#caption-badge');
  const captionTitle = document.querySelector('#caption-title');
  const captionDesc = document.querySelector('#caption-desc');
  const lightbox = document.querySelector('#gallery-lightbox');
  const lightboxImg = document.querySelector('#lightbox-img');
  const lightboxTitle = document.querySelector('#lightbox-title');
  const lightboxClose = document.querySelector('.lightbox-close');

  if (!stage || !indicatorsContainer) return;

  const english = document.documentElement.lang === 'en';

  const galleryDataZh = {
    settings: [
      {
        title: '通用设置',
        badge: '偏好设置',
        windowTitle: '通用设置 · Remote Buddy',
        src: 'assets/screenshots/general-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 通用设置界面：三项状态概览、向导入口与分组偏好',
        desc: '查看权限与麦克风、遥控器连接和输入法集成三项状态，点击卡片直达对应设置。下方可重新运行向导，或调整应用显示、启动行为和语言。'
      },
      {
        title: '权限与麦克风',
        badge: '权限与驱动',
        windowTitle: '权限与麦克风 · Remote Buddy',
        src: 'assets/screenshots/permissions-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 权限与麦克风界面：蓝牙、输入监控、辅助功能权限与虚拟麦克风驱动状态',
        desc: '检查蓝牙、输入监控和辅助功能权限，以及 Remote Buddy Mic 驱动状态。缺少权限或驱动时，按页面提示处理。'
      },
      {
        title: '遥控器连接',
        badge: '多设备管理',
        windowTitle: '遥控器连接 · Remote Buddy',
        src: 'assets/screenshots/connection-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 遥控器连接界面：已添加的 G9N9N 遥控器、电量、麦克风增益与设备信息',
        desc: '查看已添加遥控器的连接状态、电量和设备信息，为每台设备单独调整麦克风增益（0–24 dB）。'
      },
      {
        title: '输入法集成',
        badge: '语音工具',
        windowTitle: '输入法与语音工具集成 · Remote Buddy',
        src: 'assets/screenshots/integration-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 输入法与语音工具集成界面：当前语音触发方式、微信输入法、豆包输入法、Voice Buddy（语音搭子）、网易叭哥说、Typeless、macOS 听写等配置入口',
        desc: '查看当前语音触发方式（热键与点按模式）和已选择的输入工具，通过向导调整热键、配置输入工具并完成语音测试生效。'
      },
      {
        title: '按键映射',
        badge: '核心按键映射',
        windowTitle: '按键映射 · Remote Buddy',
        src: 'assets/screenshots/mapping-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 按键映射设置界面：可视化遥控器按键映射，支持单击、双击、长按与自定义快捷键',
        desc: '点击遥控器按键，设置单击、双击或长按动作。每台遥控器独立保存配置，也可设置自定义快捷键。'
      },
      {
        title: '常用语编辑',
        badge: '常用语库管理',
        windowTitle: '常用语调整 · Remote Buddy',
        src: 'assets/screenshots/phrases-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 常用语调整界面：小米遥控器按键分配、常用语库与短语编辑管理',
        desc: '编辑常用语列表，为方向键、确定键及功能键分配短语。在常用语面板中用遥控器选择要输入的内容。'
      },
      {
        title: '应用集成',
        badge: '可选自动聚焦',
        windowTitle: '应用集成 · Remote Buddy',
        src: 'assets/screenshots/application-integration-zh.jpg?v=261117screens',
        alt: '应用集成界面：微信、Antigravity、ChatGPT、Claude、DeepSeek Harness 和 WorkBuddy 的开关与输入位置说明',
        desc: '分别或批量开启集成，优先保留选中的输入框，需要时再定位对话输入框。聚焦失败仍可继续语音，必要时用 Command+V 粘贴结果。'
      },
      {
        title: '关于搭子',
        badge: '版本与更新',
        windowTitle: '关于搭子 · Remote Buddy',
        src: 'assets/screenshots/about-zh.jpg?v=261117screens',
        alt: 'Remote Buddy 关于界面：应用版本、测试版与软件更新检查、诊断与本地日志、官网与 GitHub 下载链接',
        desc: '集中查看当前版本、切换测试版（Preview）接收开关、检查软件更新、复制诊断信息或打开本地日志，并提供官网与 GitHub Releases 双下载入口。'
      }
    ],
    wizard: [
      {
        title: '第 1 步 · 权限与麦克风',
        badge: '向导 · 权限与驱动',
        windowTitle: '权限与麦克风 · 首次使用向导',
        src: 'assets/screenshots/wizard-permissions-zh.jpg?v=261117screens',
        alt: '首次使用向导：蓝牙、输入监控、辅助功能权限及虚拟麦克风驱动检查',
        desc: '按提示授予蓝牙、输入监控和辅助功能权限，并检查 Remote Buddy Mic 虚拟麦克风驱动与音频输出。左下角可切换中文或英文。'
      },
      {
        title: '第 2 步 · 设备类型',
        badge: '向导 · 设备准备',
        windowTitle: '设备类型 · 首次使用向导',
        src: 'assets/screenshots/wizard-source-zh.jpg?v=261117screens',
        alt: '首次使用向导：遥控器型号列表与选中的 Chromecast Voice Remote（G9N9N）实拍图',
        desc: '选择遥控器型号，查看右侧的设备外观。各型号的适配进度见下方“兼容范围”。'
      },
      {
        title: '第 3 步 · 连接遥控器',
        badge: '向导 · 蓝牙配对',
        windowTitle: '连接遥控器 · 首次使用向导',
        src: 'assets/screenshots/wizard-remote-zh.jpg?v=261117screens',
        alt: '首次使用向导：连接遥控器步骤，图解配对按键与实时连接检测',
        desc: '按提示完成蓝牙配对。只有一台匹配设备时会自动选中，再按普通按键确认连接。'
      },
      {
        title: '第 4 步 · 按键测试',
        badge: '向导 · 按键反馈',
        windowTitle: '按键测试 · 首次使用向导',
        src: 'assets/screenshots/wizard-controls-zh.jpg?v=261117screens',
        alt: '首次使用向导：普通按键测试清单与实时检测状态',
        desc: '按三个不同的普通按键，确认向导收到输入。G9N9N 同样逐个测试普通按键。'
      },
      {
        title: '第 5 步 · 语音热键',
        badge: '向导 · 热键与模式',
        windowTitle: '选择语音热键 · 首次使用向导',
        src: 'assets/screenshots/wizard-driver-zh.jpg?v=261117screens',
        alt: '首次使用向导：选择发送给输入工具的语音热键（Fn/地球键或自定义快捷键）及点按模式',
        desc: '选择发送给输入工具的语音热键（默认 Fn/地球键，也支持预设或自定义快捷键），并设置按住说话或点按模式，通过后续语音测试后生效。'
      },
      {
        title: '第 6 步 · 输入工具',
        badge: '向导 · 工具设置',
        windowTitle: '输入工具 · 首次使用向导',
        src: 'assets/screenshots/wizard-tool-zh.jpg?v=261117screens',
        alt: '首次使用向导：输入工具选择与图文分步设置指引，包含微信输入法、豆包等操作步骤',
        desc: '选择输入法或听写工具，按右侧步骤完成麦克风与对应语音热键及录音模式设置；也可点击一键切换当前系统输入法。'
      },
      {
        title: '第 7 步 · 语音测试',
        badge: '向导 · 语音测试',
        windowTitle: '语音测试 · 首次使用向导',
        src: 'assets/screenshots/wizard-test-zh.jpg?v=261117screens',
        alt: '首次使用向导：语音测试输入框、麦克风增益与检测状态',
        desc: '按住语音键说一句话，松开后检查输入工具返回的文字。需要时调整麦克风增益。图中为等待试说的状态。'
      }
    ]
  };

  const galleryDataEn = {
    settings: [
      {
        title: 'General Settings',
        badge: 'Preferences',
        windowTitle: 'General Settings · Remote Buddy',
        src: 'assets/screenshots/general-en.jpg?v=261117screens',
        alt: 'Remote Buddy General Settings interface: three status cards, setup wizard entry, and grouped preferences',
        desc: 'Review permissions & microphone, connected remotes, and input integration in three status cards. Open settings from each card, restart setup, or adjust display, launch, and language preferences.'
      },
      {
        title: 'Permissions & Microphone',
        badge: 'Permissions & Driver',
        windowTitle: 'Permissions & Microphone · Remote Buddy',
        src: 'assets/screenshots/permissions-en.jpg?v=261117screens',
        alt: 'Remote Buddy Permissions interface: Bluetooth, Input Monitoring, Accessibility permissions and virtual microphone driver status',
        desc: 'Check Bluetooth, Input Monitoring, and Accessibility permissions, plus the Remote Buddy Mic driver. Follow the page’s instructions if anything is missing.'
      },
      {
        title: 'Devices',
        badge: 'Multi-device',
        windowTitle: 'Devices · Remote Buddy',
        src: 'assets/screenshots/connection-en.jpg?v=261117screens',
        alt: 'Remote Buddy Devices interface: connected G9N9N remote, battery level, microphone gain, and device information',
        desc: 'Check connection status, battery level, and device details for added remotes. Adjust microphone gain for each device (0–24 dB).'
      },
      {
        title: 'Voice Tools',
        badge: 'Integrations',
        windowTitle: 'Voice Tools Integration · Remote Buddy',
        src: 'assets/screenshots/integration-en.jpg?v=261117screens',
        alt: 'Remote Buddy Voice Tools interface: current voice trigger and setup guides for WeType, Doubao, Voice Buddy, NetEase Bageshuo, Typeless, macOS Dictation, and other tools',
        desc: 'Review the active voice trigger shortcut, tap mode, and selected input tool, then launch the integration wizard to customize hotkeys, configure your tool, and verify with a voice test.'
      },
      {
        title: 'Button Mapping',
        badge: 'Core Mapping',
        windowTitle: 'Button Mapping · Remote Buddy',
        src: 'assets/screenshots/mapping-en.jpg?v=261117screens',
        alt: 'Remote Buddy Button Mapping interface: visual remote layout mapping single, double, and long press shortcuts',
        desc: 'Click a remote button to configure its single, double, or long press action. Each remote saves its own mappings, including custom shortcuts.'
      },
      {
        title: 'Common Phrases',
        badge: 'Phrase Editor',
        windowTitle: 'Common Phrases · Remote Buddy',
        src: 'assets/screenshots/phrases-en.jpg?v=261117screens',
        alt: 'Remote Buddy Common Phrases interface: Xiaomi remote button assignments and custom phrase library editor',
        desc: 'Edit phrase lists and assign phrases to the directional pad, OK, and extra remote buttons. Use the remote to choose text from the phrase panel.'
      },
      {
        title: 'App Integrations',
        badge: 'Optional Focus',
        windowTitle: 'App Integrations · Remote Buddy',
        src: 'assets/screenshots/application-integration-en.jpg?v=261117screens',
        alt: 'App integrations: switches for WeChat, Antigravity, ChatGPT, Claude, DeepSeek Harness, and WorkBuddy, selected-input behavior, and voice-key guidance',
        desc: 'Keep your selected text box, or locate the conversation input when needed. Enable apps individually or together. Voice continues if focus fails; use Command+V to paste the result if needed.'
      },
      {
        title: 'About Remote Buddy',
        badge: 'Version & Updates',
        windowTitle: 'About Remote Buddy · Remote Buddy',
        src: 'assets/screenshots/about-en.jpg?v=261117screens',
        alt: 'Remote Buddy About interface: version, preview updates switch, software update check, diagnostics and logs, website and GitHub download links',
        desc: 'Check the current version, toggle preview updates, check for software updates, copy diagnostics or open local logs, and access both direct website downloads and GitHub Releases.'
      }
    ],
    wizard: [
      {
        title: 'Step 1 · Permissions & Mic',
        badge: 'Wizard · System & Driver',
        windowTitle: 'Permissions & Microphone · Setup Wizard',
        src: 'assets/screenshots/wizard-permissions-en.jpg?v=261117screens',
        alt: 'Setup Wizard: System permissions check for Bluetooth, Input Monitoring, Accessibility, and virtual microphone driver',
        desc: 'Follow the prompts to grant Bluetooth, Input Monitoring, and Accessibility permissions, and verify the Remote Buddy Mic driver and audio output. Switch between English and Chinese at the bottom left.'
      },
      {
        title: 'Step 2 · Device Type',
        badge: 'Wizard · Device Choice',
        windowTitle: 'Control Source · Setup Wizard',
        src: 'assets/screenshots/wizard-source-en.jpg?v=261117screens',
        alt: 'Setup Wizard: remote model list with the selected Chromecast Voice Remote (G9N9N) photograph',
        desc: 'Choose a remote model and view its appearance on the right. See Compatibility below for each model’s support status.'
      },
      {
        title: 'Step 3 · Connect Remote',
        badge: 'Wizard · Pairing',
        windowTitle: 'Connect Remote · Setup Wizard',
        src: 'assets/screenshots/wizard-remote-en.jpg?v=261117screens',
        alt: 'Setup Wizard: Remote pairing illustration and live connection status check',
        desc: 'Follow the Bluetooth pairing instructions. A single matching device is selected automatically; press an ordinary button to confirm the connection.'
      },
      {
        title: 'Step 4 · Button Test',
        badge: 'Wizard · Button Check',
        windowTitle: 'Button Test · Setup Wizard',
        src: 'assets/screenshots/wizard-controls-en.jpg?v=261117screens',
        alt: 'Setup Wizard: ordinary button checklist with live detection status',
        desc: 'Press three different ordinary buttons to check that input arrives. For G9N9N, test individual ordinary buttons in the same way.'
      },
      {
        title: 'Step 5 · Voice Trigger',
        badge: 'Wizard · Hotkey & Mode',
        windowTitle: 'Voice Trigger · Setup Wizard',
        src: 'assets/screenshots/wizard-driver-en.jpg?v=261117screens',
        alt: 'Setup Wizard: choose voice shortcut (Fn/Globe or custom shortcut) and tap/hold mode',
        desc: 'Pick the voice shortcut sent to your input tool (Fn/Globe by default, presets, or custom hotkey) and choose Hold or Tap Mode. New settings take effect once the voice test passes.'
      },
      {
        title: 'Step 6 · Input Tool',
        badge: 'Wizard · Tool Setup',
        windowTitle: 'Input Tool · Setup Wizard',
        src: 'assets/screenshots/wizard-tool-en.jpg?v=261117screens',
        alt: 'Setup Wizard: Voice input tool selection with visual step-by-step setup guides',
        desc: 'Choose your input method or dictation tool and follow the guided steps on the right to configure Remote Buddy Mic and your voice shortcut.'
      },
      {
        title: 'Step 7 · Voice Test',
        badge: 'Wizard · Speech Test',
        windowTitle: 'Voice Test · Setup Wizard',
        src: 'assets/screenshots/wizard-test-en.jpg?v=261117screens',
        alt: 'Setup Wizard: voice test text field, microphone gain, and test status',
        desc: 'Hold the voice button, speak, then release and check the text returned by your input tool. Adjust microphone gain if needed. The screenshot shows the waiting state.'
      }
    ]
  };

  const galleryData = english ? galleryDataEn : galleryDataZh;
  let currentTrack = 'settings';
  let currentIndex = 0;

  function renderTrack(trackKey, startIndex) {
    currentTrack = trackKey;
    const items = galleryData[trackKey] || [];
    currentIndex = Math.max(0, Math.min(startIndex || 0, items.length - 1));

    stage.innerHTML = '';
    indicatorsContainer.innerHTML = '';

    items.forEach((item, index) => {
      const slide = document.createElement('div');
      slide.className = 'stage-slide';
      slide.setAttribute('role', 'group');
      slide.setAttribute('aria-label', `${item.title} (${index + 1}/${items.length})`);
      slide.dataset.index = index;

      slide.innerHTML = `
        <div class="window-top" aria-hidden="true">
          <div class="window-dots"><i></i><i></i><i></i></div>
          <span class="window-title">${item.windowTitle}</span>
        </div>
        <img src="${item.src}" alt="${item.alt}" width="1020" height="772" loading="${index === 0 ? 'eager' : 'lazy'}">
      `;

      slide.addEventListener('click', () => {
        if (index === currentIndex) {
          openLightbox(item);
        } else {
          goToIndex(index);
        }
      });

      stage.appendChild(slide);

      const ind = document.createElement('button');
      ind.className = 'gallery-indicator-btn' + (index === currentIndex ? ' is-active' : '');
      ind.type = 'button';
      ind.innerHTML = `<span class="indicator-step">${index + 1}</span><span>${item.title}</span>`;
      ind.addEventListener('click', () => goToIndex(index));
      indicatorsContainer.appendChild(ind);
    });

    updateStage();
  }

  function updateStage() {
    const slides = stage.querySelectorAll('.stage-slide');
    const indicators = indicatorsContainer.querySelectorAll('.gallery-indicator-btn');
    const items = galleryData[currentTrack] || [];
    const currentItem = items[currentIndex];

    slides.forEach((slide, index) => {
      slide.classList.remove('slide-active', 'slide-prev', 'slide-next', 'slide-hidden-left', 'slide-hidden-right');
      const diff = index - currentIndex;
      if (diff === 0) {
        slide.classList.add('slide-active');
        slide.setAttribute('tabindex', '0');
      } else if (diff === -1) {
        slide.classList.add('slide-prev');
        slide.setAttribute('tabindex', '-1');
      } else if (diff === 1) {
        slide.classList.add('slide-next');
        slide.setAttribute('tabindex', '-1');
      } else if (diff < -1) {
        slide.classList.add('slide-hidden-left');
        slide.setAttribute('tabindex', '-1');
      } else {
        slide.classList.add('slide-hidden-right');
        slide.setAttribute('tabindex', '-1');
      }
    });

    indicators.forEach((ind, index) => {
      ind.classList.toggle('is-active', index === currentIndex);
      ind.setAttribute('aria-selected', index === currentIndex ? 'true' : 'false');
    });

    if (currentItem) {
      if (captionBadge) captionBadge.textContent = currentItem.badge;
      if (captionTitle) captionTitle.textContent = currentItem.title;
      if (captionDesc) captionDesc.textContent = currentItem.desc;
    }
  }

  function goToIndex(newIndex) {
    const items = galleryData[currentTrack] || [];
    if (!items.length) return;
    currentIndex = (newIndex + items.length) % items.length;
    updateStage();
  }

  function openLightbox(item) {
    if (!lightbox || !lightboxImg) return;
    lightboxImg.src = item.src;
    lightboxImg.alt = item.alt;
    if (lightboxTitle) lightboxTitle.textContent = item.windowTitle;
    if (typeof lightbox.showModal === 'function') {
      lightbox.showModal();
    }
  }

  function closeLightbox() {
    if (!lightbox) return;
    if (typeof lightbox.close === 'function') {
      lightbox.close();
    }
  }

  if (prevBtn) prevBtn.addEventListener('click', () => goToIndex(currentIndex - 1));
  if (nextBtn) nextBtn.addEventListener('click', () => goToIndex(currentIndex + 1));

  categoryBtns.forEach(btn => {
    const label = btn.textContent.replace(/\s*\(\d+\)\s*$/, '');
    btn.textContent = `${label} (${(galleryData[btn.dataset.track] || []).length})`;
    btn.addEventListener('click', () => {
      categoryBtns.forEach(b => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      renderTrack(btn.dataset.track, 0);
    });
  });

  if (lightboxClose) lightboxClose.addEventListener('click', closeLightbox);
  if (lightbox) {
    lightbox.addEventListener('click', event => {
      if (event.target === lightbox) closeLightbox();
    });
  }

  stage.addEventListener('keydown', event => {
    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      goToIndex(currentIndex - 1);
    } else if (event.key === 'ArrowRight') {
      event.preventDefault();
      goToIndex(currentIndex + 1);
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      const currentItem = (galleryData[currentTrack] || [])[currentIndex];
      if (currentItem) openLightbox(currentItem);
    }
  });

  let touchStartX = 0;
  stage.addEventListener('touchstart', event => {
    touchStartX = event.changedTouches[0].screenX;
  }, { passive: true });
  stage.addEventListener('touchend', event => {
    const diff = event.changedTouches[0].screenX - touchStartX;
    if (Math.abs(diff) > 40) {
      if (diff > 0) goToIndex(currentIndex - 1);
      else goToIndex(currentIndex + 1);
    }
  }, { passive: true });

  renderTrack('settings', 0);
})();


