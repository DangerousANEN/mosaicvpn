/**
 * MosaicVPN — /setup.html client application
 * Handles website-first onboarding: email/password auth (primary),
 * platform detection, honest payment options, and enrollment issuance.
 */

(function () {
  'use strict';

  // Storage keys matching cabinet.html
  var TOKEN_KEY = 'mv_session_token';
  var GIFT_KEY = 'mv_pending_gift';

  // In-memory fallbacks for private browsing / blocked storage
  var memoryStorage = {};

  function storageGet(key, isSession) {
    try {
      var store = isSession ? window.sessionStorage : window.localStorage;
      if (store) return store.getItem(key);
    } catch (e) {
      /* ignore */
    }
    return memoryStorage[key] || null;
  }

  function storageSet(key, value, isSession) {
    try {
      var store = isSession ? window.sessionStorage : window.localStorage;
      if (store) store.setItem(key, value);
    } catch (e) {
      /* ignore */
    }
    memoryStorage[key] = value;
  }

  function storageRemove(key, isSession) {
    try {
      var store = isSession ? window.sessionStorage : window.localStorage;
      if (store) store.removeItem(key);
    } catch (e) {
      /* ignore */
    }
    delete memoryStorage[key];
  }

  // Generate high-entropy state for app auth (min 16 chars)
  function generateAppState() {
    try {
      if (window.crypto && window.crypto.getRandomValues) {
        var arr = new Uint8Array(16);
        window.crypto.getRandomValues(arr);
        return Array.from(arr, function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
      }
    } catch (e) {
      /* fallback */
    }
    var rnd = Math.random().toString(36).substring(2) + Math.random().toString(36).substring(2);
    return (rnd + '1234567890123456').substring(0, 32);
  }

  // App state
  var state = {
    token: storageGet(TOKEN_KEY, false),
    profile: null,
    giftToken: null,
    currentPlatform: 'android',
    enrollment: null,
    // Checkout selection: filled from /api/checkout/options + profile billing.
    dailyPriceRub: 1,
    checkoutDays: 30,
    checkoutMethod: null,
  };

  // API helper with Bearer and token query fallback
  function apiRequest(url, options) {
    options = options || {};
    options.headers = options.headers || {};
    if (state.token && !options.headers['Authorization']) {
      options.headers['Authorization'] = 'Bearer ' + state.token;
    }
    return fetch(url, options).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        return { ok: res.ok, status: res.status, data: data };
      });
    });
  }

  // DOM Elements
  var dom = {};

  function initDom() {
    dom.stepAuth = document.getElementById('step-auth');
    dom.stepAccess = document.getElementById('step-access');
    dom.stepSetup = document.getElementById('step-setup');
    dom.indStep1 = document.getElementById('ind-step-1');
    dom.indStep2 = document.getElementById('ind-step-2');
    dom.indStep3 = document.getElementById('ind-step-3');

    // Auth forms
    dom.tabRegister = document.getElementById('tab-register');
    dom.tabLogin = document.getElementById('tab-login');
    dom.formRegister = document.getElementById('form-register');
    dom.formLogin = document.getElementById('form-login');
    dom.regEmail = document.getElementById('reg-email');
    dom.regPass = document.getElementById('reg-password');
    dom.regError = document.getElementById('reg-error');
    dom.loginEmail = document.getElementById('login-email');
    dom.loginPass = document.getElementById('login-password');
    dom.loginError = document.getElementById('login-error');
    dom.btnRegister = document.getElementById('btn-register');
    dom.btnLogin = document.getElementById('btn-login');

    // Gift notification
    dom.giftNotice = document.getElementById('gift-notice');
    dom.giftSuccess = document.getElementById('gift-redeem-success');

    dom.profileSummary = document.getElementById('profile-summary-card');
    dom.userDisplayEmail = document.getElementById('user-display-email');
    dom.userDisplayId = document.getElementById('user-display-id');
    dom.accountStatusBadge = document.getElementById('account-status-badge');

    // Profile info
    dom.accountInfo = document.getElementById('account-info');
    dom.userEmail = document.getElementById('user-email');
    dom.userId = document.getElementById('user-id');
    dom.accountStatus = document.getElementById('account-status');
    dom.btnLogout = document.getElementById('btn-logout');

    // Payment step
    dom.paymentActiveNotice = document.getElementById('payment-active-notice');
    dom.paymentUnavailNotice = document.getElementById('payment-unavailable-notice');
    dom.paymentFormContainer = document.getElementById('payment-form-container');
    dom.paymentForm = document.getElementById('payment-form');
    dom.btnToSetup = document.getElementById('btn-to-setup');

    // Platform & download
    dom.dlBtnPrimary = document.getElementById('dl-btn-primary');
    dom.dlBtnSecondary = document.getElementById('dl-btn-secondary');
    dom.dlTitle = document.getElementById('dl-title');
    dom.dlDescription = document.getElementById('dl-description');
    dom.dlNotes = document.getElementById('dl-notes');
    dom.appleNotice = document.getElementById('apple-status-note');
    dom.dlContentBox = document.getElementById('dl-content-box');

    // Enrollment
    dom.btnIssueEnrollment = document.getElementById('btn-issue-enrollment');
    dom.enrollmentBox = document.getElementById('enrollment-box');
    dom.btnOpenApp = document.getElementById('btn-open-app');
    dom.enrollmentReadyStatus = document.getElementById('enrollment-ready-status');
    dom.enrollmentCodeVal = document.getElementById('enrollment-code-val');
    dom.btnCopyCode = document.getElementById('btn-copy-code');
    dom.manualCallbackLink = document.getElementById('manual-callback-link');
  }

  // Safe Platform Metadata (Verified Releases Only)
  var PLATFORMS = {
    android: {
      title: 'Android',
      desc: 'Мобильный клиент MosaicVPN (Atlas Zen UI) для телефонов и планшетов.',
      primaryName: 'Скачать APK (53 МБ)',
      primaryUrl: '/assets/MosaicVPN-Android-v0.3.60.apk',
      secondaryName: 'Зеркало GitHub',
      secondaryUrl: 'https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.60/MosaicVPN-Android-v0.3.60.apk',
      note: 'Версия v0.3.60 · Android 7.0+ · ARM64/ARM32',
      isAvailable: true,
    },
    windows: {
      title: 'Windows',
      desc: 'Клиент со службой сетевой защиты и Kill Switch для Windows 10/11.',
      primaryName: 'Скачать Setup x64 (24.7 МБ)',
      primaryUrl: 'https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.60/MosaicVPN-Setup-x64-v0.3.60.exe',
      secondaryName: 'Portable .zip (36.8 МБ)',
      secondaryUrl: 'https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.60/MosaicVPN-Portable-x64-v0.3.60.zip',
      note: 'Версия v0.3.60 · Windows 10/11 x64',
      isAvailable: true,
    },
    linux: {
      title: 'Linux',
      desc: 'Пакет для Ubuntu/Debian и переносимый архив с ядром маршрутизации.',
      primaryName: 'Скачать .deb (31.7 МБ)',
      primaryUrl: 'https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.60/MosaicVPN_0.3.60_amd64.deb',
      secondaryName: 'Portable .tar.gz (41.5 МБ)',
      secondaryUrl: 'https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.60/MosaicVPN-Portable-x86_64-v0.3.60.tar.gz',
      note: 'Версия v0.3.60 · glibc 2.31+ x86_64',
      isAvailable: true,
    },
    apple: {
      title: 'iOS & macOS',
      desc: 'Нативное приложение MosaicVPN для платформ Apple не выпущено.',
      isAvailable: false,
      note: 'Официальные сборки MosaicVPN для iOS и macOS в настоящее время отсутствуют. Сервис не даёт неподтверждённых обещаний о сроках релиза. Для подключения на устройствах Apple вы можете использовать конфигурацию профиля из личного кабинета.',
    },
  };

  function detectPlatform() {
    var ua = (navigator.userAgent || '').toLowerCase();
    var plat = (navigator.platform || '').toLowerCase();

    if (/android/i.test(ua)) return 'android';
    if (/iphone|ipad|ipod|mac/i.test(ua) || /mac/i.test(plat)) return 'apple';
    if (/win/i.test(ua) || /win/i.test(plat)) return 'windows';
    if (/linux/i.test(ua) || /linux/i.test(plat)) return 'linux';
    return 'android';
  }

  function setPlatform(p) {
    if (!PLATFORMS[p]) p = 'android';
    state.currentPlatform = p;

    document.querySelectorAll('.platform-card-btn').forEach(function (btn) {
      var matches = btn.id === 'platform-tab-' + p;
      btn.classList.toggle('active', matches);
      btn.setAttribute('aria-selected', matches ? 'true' : 'false');
    });

    var data = PLATFORMS[p];
    if (!data.isAvailable) {
      dom.dlContentBox.classList.add('hidden');
      dom.appleNotice.classList.remove('hidden');
      dom.appleNotice.textContent = data.note;
    } else {
      dom.appleNotice.classList.add('hidden');
      dom.dlContentBox.classList.remove('hidden');
      dom.dlTitle.textContent = data.title;
      dom.dlDescription.textContent = data.desc;
      dom.dlBtnPrimary.textContent = data.primaryName;
      dom.dlBtnPrimary.href = data.primaryUrl;
      if (data.secondaryUrl) {
        dom.dlBtnSecondary.textContent = data.secondaryName;
        dom.dlBtnSecondary.href = data.secondaryUrl;
        dom.dlBtnSecondary.classList.remove('hidden');
      } else {
        dom.dlBtnSecondary.classList.add('hidden');
      }
      dom.dlNotes.textContent = data.note;
    }
  }

  // Parse and safely clean fragments immediately
  function inspectUrlFragments() {
    var hash = window.location.hash || '';
    if (!hash) return;

    var matchGift = hash.match(/#(?:gift|invite)=([A-Za-z0-9_-]+)/);

    // Strip hash immediately to prevent token exposure in address bar
    if (window.history && window.history.replaceState) {
      window.history.replaceState(null, document.title, window.location.pathname + window.location.search);
    } else {
      window.location.hash = '';
    }

    if (matchGift && matchGift[1]) {
      state.giftToken = matchGift[1];
      storageSet(GIFT_KEY, matchGift[1], true);
      showGiftNotice('Код подарка распознан! Войдите или создайте аккаунт для зачисления.');
    }
  }

  function showGiftNotice(text) {
    if (dom.giftNotice) {
      dom.giftNotice.textContent = text;
      dom.giftNotice.classList.remove('hidden');
    }
  }

  function redeemPendingGift() {
    var gift = state.giftToken || storageGet(GIFT_KEY, true);
    if (!gift || !state.token) return;

    apiRequest('/api/invites/redeem', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: state.token, invite_token: gift }),
    }).then(function (res) {
      if (res.ok) {
        storageRemove(GIFT_KEY, true);
        state.giftToken = null;
        if (dom.giftNotice) dom.giftNotice.classList.add('hidden');
        if (dom.giftSuccess) {
          dom.giftSuccess.textContent = res.data.message || 'Подарок успешно активирован!';
          dom.giftSuccess.classList.remove('hidden');
        }
        loadProfile();
      }
    }).catch(function () {
      /* endpoint may be owned/added by backend agent */
    });
  }

  function setToken(token) {
    state.token = token;
    storageSet(TOKEN_KEY, token, false);
  }

  function logout() {
    state.token = null;
    state.profile = null;
    storageRemove(TOKEN_KEY, false);

    // Reset view to Step 1
    dom.stepAuth.classList.remove('hidden');
    dom.stepAccess.classList.add('hidden');
    dom.stepSetup.classList.add('hidden');
    dom.indStep1.className = 'step-indicator active';
    dom.indStep2.className = 'step-indicator';
    dom.indStep3.className = 'step-indicator';
    dom.accountInfo.classList.add('hidden');
    if (dom.profileSummary) dom.profileSummary.classList.add('hidden');
  }

  function switchAuthTab(isRegister) {
    dom.tabRegister.classList.toggle('active', isRegister);
    dom.tabLogin.classList.toggle('active', !isRegister);
    dom.formRegister.classList.toggle('hidden', !isRegister);
    dom.formLogin.classList.toggle('hidden', isRegister);
  }

  // Registration handler
  function handleRegister(e) {
    e.preventDefault();
    dom.regError.textContent = '';
    var email = (dom.regEmail.value || '').trim();
    var pass = dom.regPass.value || '';

    if (!email || !/@/.test(email)) {
      dom.regError.textContent = 'Введите корректный email-адрес.';
      return;
    }
    if (pass.length < 10) {
      dom.regError.textContent = 'Пароль должен содержать от 10 символов.';
      return;
    }

    dom.btnRegister.disabled = true;
    dom.btnRegister.textContent = 'Регистрация…';

    apiRequest('/api/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email, password: pass }),
    }).then(function (res) {
      if (!res.ok) {
        dom.regError.textContent = res.data.error || 'Ошибка при регистрации.';
        return;
      }
      setToken(res.data.token);
      redeemPendingGift();
      loadProfile();
    }).catch(function () {
      dom.regError.textContent = 'Не удалось связаться с сервером.';
    }).finally(function () {
      dom.btnRegister.disabled = false;
      dom.btnRegister.textContent = 'Создать аккаунт';
    });
  }

  // Login handler
  function handleLogin(e) {
    e.preventDefault();
    dom.loginError.textContent = '';
    var email = (dom.loginEmail.value || '').trim();
    var pass = dom.loginPass.value || '';

    if (!email || !pass) {
      dom.loginError.textContent = 'Заполните оба поля.';
      return;
    }

    dom.btnLogin.disabled = true;
    dom.btnLogin.textContent = 'Вход…';

    apiRequest('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email, password: pass }),
    }).then(function (res) {
      if (!res.ok) {
        dom.loginError.textContent = res.data.error || 'Неверный email или пароль.';
        return;
      }
      setToken(res.data.token);
      redeemPendingGift();
      loadProfile();
    }).catch(function () {
      dom.loginError.textContent = 'Не удалось связаться с сервером.';
    }).finally(function () {
      dom.btnLogin.disabled = false;
      dom.btnLogin.textContent = 'Войти';
    });
  }

  // Load Profile and Route Steps
  function loadProfile() {
    if (!state.token) {
      logout();
      return;
    }

    apiRequest('/api/profile?token=' + encodeURIComponent(state.token)).then(function (res) {
      if (!res.ok) {
        // Try fallback to /api/billing/profile
        return apiRequest('/api/billing/profile?token=' + encodeURIComponent(state.token));
      }
      return res;
    }).then(function (res) {
      if (!res.ok || !res.data) {
        logout();
        return;
      }

      state.profile = res.data;
      renderProfileUI(res.data);
    }).catch(function () {
      // offline or server glitch
    });
  }

  function renderProfileUI(profile) {
    var displayId = profile.account_id != null ? profile.account_id : (profile.telegram_id != null ? profile.telegram_id : '—');
    var displayEmail = profile.email || profile.username || 'Пользователь';

    dom.accountInfo.classList.remove('hidden');
    dom.userEmail.textContent = displayEmail;
    dom.userId.textContent = 'ID: ' + displayId;

    if (dom.profileSummary) {
      dom.profileSummary.classList.remove('hidden');
      if (dom.userDisplayEmail) dom.userDisplayEmail.textContent = displayEmail;
      if (dom.userDisplayId) dom.userDisplayId.textContent = 'ID аккаунта: ' + displayId;
    }

    var days = Number(profile.days_left) || 0;
    var isActive = days > 0;

    var statusText = isActive
      ? 'Доступ активен: осталось ' + days + ' дн.'
      : 'Доступ не активен';
    var statusClass = 'status-badge ' + (isActive ? 'active status-active' : 'expired status-expired');

    dom.accountStatus.textContent = statusText;
    dom.accountStatus.className = statusClass;

    if (dom.accountStatusBadge) {
      dom.accountStatusBadge.textContent = statusText;
      dom.accountStatusBadge.className = statusClass;
    }

    // Hide Auth step
    dom.stepAuth.classList.add('hidden');
    dom.indStep1.className = 'step-indicator completed';

    if (isActive) {
      // Direct to Step 3 (Setup)
      dom.stepAccess.classList.add('hidden');
      dom.stepSetup.classList.remove('hidden');
      dom.indStep2.className = 'step-indicator completed';
      dom.indStep3.className = 'step-indicator active';
    } else {
      // Show Step 2 (Access / Payment)
      dom.stepAccess.classList.remove('hidden');
      dom.stepSetup.classList.add('hidden');
      dom.indStep2.className = 'step-indicator active';
      dom.indStep3.className = 'step-indicator';

      checkCheckoutOptions();
    }
  }

  // Check Honest Payment Options + build payment UI from live API data
  function fetchCheckoutOptions() {
    return apiRequest('/api/checkout/options').then(function (res) {
      if (!res.ok) throw new Error('options failed');
      var providers = (res.data && res.data.providers) || [];
      var lava = providers.find(function (p) { return p.id === 'lava'; });
      return lava || null;
    });
  }

  function renderPaymentUI(lava) {
    var hasOnlinePayment = lava && lava.available && Array.isArray(lava.methods) && lava.methods.length > 0;
    if (!hasOnlinePayment) {
      // Honest: provider card/sbp unavailable on site
      dom.paymentUnavailNotice.classList.remove('hidden');
      dom.paymentFormContainer.classList.add('hidden');
      return;
    }
    dom.paymentUnavailNotice.classList.add('hidden');
    dom.paymentFormContainer.classList.remove('hidden');

    // Days presets derived from per-day price. /api/checkout/options does not
    // carry the tariff, so take it from the profile payload
    // (billing.price_per_day_rub); fall back to 1 RUB = 1 day.
    var daily = 1;
    var billing = (state.profile && state.profile.billing) || {};
    var rawDaily = lava && lava.daily_price_rub !== undefined && lava.daily_price_rub !== null
      ? lava.daily_price_rub
      : billing.price_per_day_rub;
    var parsedDaily = parseInt(rawDaily, 10);
    if (!isNaN(parsedDaily) && parsedDaily > 0) daily = parsedDaily;
    state.dailyPriceRub = daily;
    if (daily === 1) {
      state.checkoutDays = state.checkoutDays || 30;
    } else {
      state.checkoutDays = Math.max(1, Math.round((state.checkoutDays || 30 * daily) / daily));
    }
    var presets = [3, 7, 30];
    var presetsBox = document.getElementById('plan-presets');
    presetsBox.innerHTML = '';
    presets.forEach(function (d) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'btn btn-outline';
      b.dataset.days = String(d);
      b.textContent = d + ' дн. — ' + (d * daily) + ' ₽';
      b.style.minHeight = '38px';
      b.addEventListener('click', function () {
        state.checkoutDays = d;
        var customInput = document.getElementById('custom-days-input');
        if (customInput) customInput.value = '';
        updatePlanUI(daily);
      });
      presetsBox.appendChild(b);
    });

    // Custom amount input
    var customWrap = document.createElement('div');
    customWrap.style.cssText = 'display:flex; align-items:center; gap:6px;';
    var customInput = document.createElement('input');
    customInput.type = 'number';
    customInput.id = 'custom-days-input';
    customInput.min = '1';
    customInput.max = '3650';
    customInput.placeholder = 'Своё кол-во';
    customInput.style.cssText = 'width:120px; height:38px; padding:4px 8px; border:1px solid var(--border); border-radius:8px; background:var(--elev); color:var(--text); font-size:14px;';
    var customLabel = document.createElement('span');
    customLabel.textContent = 'дней';
    customLabel.style.cssText = 'font-size:14px; color:var(--muted);';
    customInput.addEventListener('input', function () {
      var v = parseInt(customInput.value, 10);
      if (!isNaN(v) && v >= 1) {
        state.checkoutDays = Math.min(v, 3650);
        updatePlanUI(daily);
      }
    });
    customWrap.appendChild(customInput);
    customWrap.appendChild(customLabel);
    presetsBox.appendChild(customWrap);

    var methods = lava.methods.slice();
    if (methods.length > 0) state.checkoutMethod = state.checkoutMethod && methods.indexOf(state.checkoutMethod) >= 0 ? state.checkoutMethod : methods[0];
    var methodsBox = document.getElementById('payment-methods');
    methodsBox.innerHTML = '';
    methods.forEach(function (m) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'btn btn-outline';
      b.dataset.method = m;
      b.textContent = m === 'sbp' ? 'СБП' : (m === 'card' ? 'Банковская карта' : m);
      b.style.minHeight = '38px';
      b.addEventListener('click', function () {
        state.checkoutMethod = m;
        updateMethodUI();
      });
      methodsBox.appendChild(b);
    });

    updatePlanUI(daily);
    updateMethodUI();
    window.__mosaicState = state;
  }

  function updatePlanUI(daily) {
    var days = state.checkoutDays || 30;
    var rub = Math.max(1, days * daily);
    var planEl = document.getElementById('plan-days-price');
    var perDayEl = document.getElementById('plan-per-day-val');
    var btn = document.getElementById('btn-checkout');
    if (planEl) planEl.textContent = 'Пополнить на ' + rub + ' ₽ — хватит на ' + days + ' дн.';
    if (perDayEl) perDayEl.textContent = String(daily);
    if (btn) btn.textContent = 'Пополнить на ' + rub + ' ₽';
    Array.prototype.forEach.call(document.querySelectorAll('#plan-presets button'), function (b) {
      var isPreset = Number(b.dataset.days) === days;
      b.classList.toggle('btn-primary', isPreset);
      b.classList.toggle('btn-outline', !isPreset);
    });
    // Deselect presets if custom value doesn't match any
    var customInput = document.getElementById('custom-days-input');
    if (customInput && customInput.value && parseInt(customInput.value, 10) === days) {
      Array.prototype.forEach.call(document.querySelectorAll('#plan-presets button[data-days]'), function (b) {
        if (Number(b.dataset.days) !== days) {
          b.classList.remove('btn-primary');
          b.classList.add('btn-outline');
        }
      });
    }
  }

  function updateMethodUI() {
    Array.prototype.forEach.call(document.querySelectorAll('#payment-methods button'), function (b) {
      b.classList.toggle('btn-primary', b.dataset.method === state.checkoutMethod);
      b.classList.toggle('btn-outline', b.dataset.method !== state.checkoutMethod);
    });
  }

  function checkCheckoutOptions() {
    fetchCheckoutOptions().then(renderPaymentUI).catch(function () {
      dom.paymentUnavailNotice.classList.remove('hidden');
      dom.paymentFormContainer.classList.add('hidden');
    });
  }

  // After returning from the payment page, re-read profile: return ≠ payment.
  function recheckProfileAfterPayment() {
    if (!state.token) return;
    apiRequest('/api/profile').then(function (res) {
      if (!res.ok) return;
      var days = res.data && (res.data.days_left !== undefined ? res.data.days_left : res.data.balance);
      var banner = document.getElementById('payment-active-notice');
      if (!banner) return;
      if (typeof days === 'number' && days > 0) {
        banner.textContent = 'Проверяем статус оплаты…';
        banner.classList.remove('hidden');
        // Poll up to 3 times: webhook may lag behind the browser return.
        var attempts = 0;
        var timer = setInterval(function () {
          attempts += 1;
          apiRequest('/api/profile').then(function (r2) {
            if (!r2.ok) return;
            var d2 = r2.data && (r2.data.days_left !== undefined ? r2.data.days_left : r2.data.balance);
            if (typeof d2 === 'number' && d2 > days) {
              clearInterval(timer);
              banner.textContent = 'Оплата зачислена: доступ ' + d2 + ' дн.';
              banner.classList.add('payment-success');
              loadProfile();
            } else if (attempts >= 3) {
              clearInterval(timer);
              banner.textContent = 'Оплата ещё подтверждается. Доступ обновится автоматически.';
            }
          }).catch(function () { if (attempts >= 3) clearInterval(timer); });
        }, 3000);
      }
    }).catch(function () {});
  }
  // Public hook for tests / step navigation
  window.__mosaicCheckout = { renderPaymentUI: renderPaymentUI, updatePlanUI: updatePlanUI, updateMethodUI: updateMethodUI, recheckProfileAfterPayment: recheckProfileAfterPayment };

  // Handle Checkout submission
  function handleCheckout(e) {
    e.preventDefault();
    var termsCheckbox = document.getElementById('terms-agree');
    if (!termsCheckbox || !termsCheckbox.checked) {
      alert('Необходимо подтвердить согласие с условиями.');
      return;
    }

    var btn = document.getElementById('btn-checkout');
    btn.disabled = true;

    var days = Math.max(1, parseInt(state.checkoutDays, 10));
    var perDay = Math.max(1, parseInt(state.dailyPriceRub, 10) || 1);
    var amountRub = days * perDay;

    apiRequest('/api/checkout/create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        provider: 'lava',
        method: state.checkoutMethod || 'card',
        days: days,
        amount_rub: amountRub,
        terms_accepted: true,
      }),
    }).then(function (res) {
      var url = res.ok && res.data ? (res.data.checkout_url || res.data.payment_url || '') : '';
      if (url) {
        // Verify secure HTTPS
        if (/^https:\/\//i.test(url)) {
          // Return from the payment page is NOT proof of payment: mark the
          // pending state so the profile is re-read after coming back.
          try { sessionStorage.setItem('mosaic_payment_pending', String(Date.now())); } catch (e) {}
          window.location.assign(url);
        } else {
          alert('Недопустимый адрес платёжного шлюза.');
        }
      } else {
        alert((res.data && res.data.error) || 'Не удалось создать платёж.');
      }
    }).catch(function () {
      alert('Сетевая ошибка при создании счёта.');
    }).finally(function () {
      btn.disabled = false;
    });
  }

  // Issue Enrollment Code & Prepare Launch Links against actual bot API contracts
  // CRITICAL CONTRACT: Do NOT drop state! Deep link and callback URL must preserve state.
  // UX TRUTH: An issued link is NOT a saved profile yet. The profile is transferred and saved
  // only after opening MosaicVPN and completing the system VPN permission flow.
  function handleIssueEnrollment() {
    if (!state.token) return;

    dom.btnIssueEnrollment.disabled = true;
    dom.btnIssueEnrollment.textContent = 'Подготовка ссылки…';

    var appState = generateAppState();

    // 1. Request app auth code with purpose='enroll' and generated state
    apiRequest('/api/app-auth/issue', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        token: state.token,
        state: appState,
        purpose: 'enroll',
      }),
    }).then(function (res) {
      var authCode = res.ok && res.data && res.data.code ? res.data.code : '';

      // 2. Also request 8-character manual pairing code from /api/link/issue
      return apiRequest('/api/link/issue', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: state.token }),
      }).then(function (linkRes) {
        var linkCode = linkRes.ok && linkRes.data && linkRes.data.code ? linkRes.data.code : '';
        return {
          authCode: authCode,
          linkCode: linkCode,
          expiresIn: (res.data && res.data.expires_in) || (linkRes.data && linkRes.data.expires_in) || 300,
        };
      });
    }).then(function (info) {
      var code = info.authCode || info.linkCode;
      if (!code) {
        alert('Не удалось подготовить код подключения. Пожалуйста, обновите страницу.');
        return;
      }

      var manualCode = info.linkCode || info.authCode;

      // Construct verified App Link / deep-link and callback URL preserving state
      var deepLink = info.authCode
        ? ('mosaicvpn://enroll/callback?code=' + encodeURIComponent(info.authCode) + '&state=' + encodeURIComponent(appState))
        : ('mosaicvpn://enroll/callback?code=' + encodeURIComponent(info.linkCode));

      var callbackUrl = info.authCode
        ? ('https://sub.zxc1x1.ru/enroll/callback?code=' + encodeURIComponent(info.authCode) + '&state=' + encodeURIComponent(appState))
        : ('https://sub.zxc1x1.ru/enroll/callback?code=' + encodeURIComponent(info.linkCode));

      state.enrollment = {
        code: code,
        manualCode: manualCode,
        state: appState,
        deepLink: deepLink,
        callbackUrl: callbackUrl,
      };

      dom.btnOpenApp.href = deepLink;
      dom.manualCallbackLink.href = callbackUrl;
      dom.enrollmentCodeVal.textContent = manualCode;

      // Truthful copy: link is prepared, but profile requires launching MosaicVPN
      dom.enrollmentReadyStatus.textContent = 'Ссылка для подключения сформирована. Откройте MosaicVPN, чтобы завершить добавление профиля.';
      dom.enrollmentReadyStatus.className = 'alert alert-info';

      dom.enrollmentBox.classList.remove('hidden');
      dom.btnIssueEnrollment.classList.add('hidden');
    }).catch(function () {
      alert('Сетевая ошибка при подготовке ссылки подключения.');
    }).finally(function () {
      dom.btnIssueEnrollment.disabled = false;
      dom.btnIssueEnrollment.textContent = 'Подготовить ссылку подключения';
    });
  }

  function copyEnrollmentCode() {
    if (!state.enrollment) return;
    var code = state.enrollment.manualCode || state.enrollment.code;
    if (!code) return;

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(code).then(function () {
        dom.btnCopyCode.textContent = 'Скопировано!';
        setTimeout(function () { dom.btnCopyCode.textContent = 'Скопировать код'; }, 2000);
      });
    } else {
      window.prompt('Скопируйте код:', code);
    }
  }

  // Setup Event Listeners
  function attachEvents() {
    dom.tabRegister.addEventListener('click', function () { switchAuthTab(true); });
    dom.tabLogin.addEventListener('click', function () { switchAuthTab(false); });

    dom.formRegister.addEventListener('submit', handleRegister);
    dom.formLogin.addEventListener('submit', handleLogin);

    dom.btnLogout.addEventListener('click', logout);

    if (dom.btnToSetup) {
      dom.btnToSetup.addEventListener('click', function () {
        dom.stepAccess.classList.add('hidden');
        dom.stepSetup.classList.remove('hidden');
        dom.indStep2.className = 'step-indicator completed';
        dom.indStep3.className = 'step-indicator active';
      });
    }

    if (dom.paymentForm) {
      dom.paymentForm.addEventListener('submit', handleCheckout);
    }

    // Platform tab selectors
    document.querySelectorAll('.platform-card-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var p = btn.getAttribute('data-platform');
        if (p) setPlatform(p);
      });
    });

    dom.btnIssueEnrollment.addEventListener('click', handleIssueEnrollment);
    dom.btnCopyCode.addEventListener('click', copyEnrollmentCode);
  }

  // Initialization
  function init() {
    initDom();
    attachEvents();
    inspectUrlFragments();

    var plat = detectPlatform();
    setPlatform(plat);

    if (state.token) {
      loadProfile();
    }

    // Return from the payment page is NOT proof of payment: if we left for the
    // gateway earlier, re-read the profile and show the honest server state.
    var pending = null;
    try { pending = sessionStorage.getItem('mosaic_payment_pending'); } catch (e) { pending = null; }
    if (pending) {
      try { sessionStorage.removeItem('mosaic_payment_pending'); } catch (e) {}
      recheckProfileAfterPayment();
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
