# Sign-up page

A single page, `app/index.html` (inline CSS and JavaScript, no build tools or
dependencies), with the heading "Create your account" and a form with an
email field (`#email`), a password field (`#password`) and a "Sign up" button
(`#submit`).

On submit, without leaving the page:

- An empty email shows "Email is required" in `#email-error`.
- An email that is not like `name@example.com` shows "Enter a valid email" in `#email-error`.
- A password shorter than 8 characters shows "Use at least 8 characters" in `#password-error`.
- A valid sign-up shows "Welcome, <email>!" in `#welcome`, for example
  "Welcome, ada@example.com!".
- After a successful sign-up, no error message from an earlier attempt remains.
