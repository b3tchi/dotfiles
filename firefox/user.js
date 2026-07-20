// user.js — linked into every profile `ff` routes to.
//
// Firefox re-reads this at each startup and copies it over prefs.js, so prefs
// stay declarative: edit here, not in about:config. Anything changed in
// about:config that is also set here is reverted on the next launch.

// Required for chrome/userChrome.css to be loaded at all. Without it the
// stylesheet is silently ignored — which is why this repo's userChrome.css
// has never taken effect on any profile.
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
