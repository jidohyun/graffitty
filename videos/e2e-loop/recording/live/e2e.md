# E2E tests

Run each test from a fresh load of the app, in the Graffitty Chromium pane.

1. Shows the sign-up form: heading "Create your account", `#email`, `#password`.
2. Requires an email: submit with an empty email and password "longenough";
   `#email-error` reads "Email is required".
3. Rejects an invalid email: email "ada@", password "longenough";
   `#email-error` reads "Enter a valid email".
4. Needs 8+ character passwords: email "ada@example.com", password "short";
   `#password-error` reads "Use at least 8 characters".
5. Welcomes a new user: email "ada@example.com", password "longenough";
   `#welcome` reads "Welcome, ada@example.com!".
6. Clears errors after success: submit empty, then submit email
   "ada@example.com" and password "longenough"; no error text remains and the
   welcome shows.

Report each test as passed or failed, with what you saw for a failure.
