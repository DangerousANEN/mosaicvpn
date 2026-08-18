# Web Account UI Validation

The local `site/cabinet.html` page was opened in Chromium after adding the e-mail/password account surface. The visible authentication gate contains the legacy Telegram pairing-code form, e-mail input, password input, separate sign-in and registration controls, and an expandable recovery action. Chromium reported no JavaScript console errors after the updated script loaded.

The final browser validation must be repeated against production after the backend and page are deployed, because actual registration requires the Remnawave provider and password recovery delivery requires configured SMTP environment variables.

A local interactive validation entered an invalid e-mail and a five-character password, then invoked registration. The form displayed the intended client-side validation error and did not make a backend request.

The local `site/admin.html` page loaded without JavaScript console errors. Because no administrator session exists in the sandbox browser, the protected controls correctly remain hidden behind the server-side session gate; their HTML and event handlers are present in the source and require production admin-session testing.
