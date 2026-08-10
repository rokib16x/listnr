import Foundation

/// The single source of truth for Listnr's version.
///
/// Kept in its own file so release tooling can find it without parsing the CLI
/// definitions, and so there is one obvious place to change at release time.
/// `scripts/check-version.sh` enforces that this, the git tag, and the CHANGELOG
/// heading all agree — a tag that disagrees with what `listnr --version` prints
/// is the kind of thing nobody notices until someone files a bug against the
/// wrong release.
public let listnrVersion = "0.1.4-beta"
