/// Build-time switches.
///
/// Public releases are built without `--dart-define=TUNETRAIL_ADMIN=true`, so
/// [kAdminBuild] is the constant `false`: every debug tool sits behind
/// `if (kAdminBuild ...)`, and the compiler drops that code from the app
/// entirely — it isn't hidden, it isn't there. The admin build (a CI
/// artifact, never published) also only unlocks debug tools for accounts the
/// server lists in its `ADMINS` setting.
library;

const bool kAdminBuild = bool.fromEnvironment('TUNETRAIL_ADMIN');

/// The game's version (1.X: major features, 1.X.X: fixes and small tweaks).
const String kAppVersion = 'Beta v1.0.4';
