import Foundation

/// Whether this person has agreed that Cal may keep what they tell it.
///
/// A separate decision from signing in, and that separation is the whole point.
/// Washington's My Health My Data Act requires opt-in that **cannot come from
/// accepting terms of use**, and separate consents for collection and for
/// sharing; California's CMIA §56.06(b) treats an app like this one as a
/// provider of health care, with $1,000 per violation and no proof of harm
/// required (LAUNCH-REQUIREMENTS §18.1). Bundling "remember me" into "sign in"
/// is exactly the pattern both were written against.
///
/// So an account is an account. Memory is a second, explicit yes.
///
/// ⚠️ **The copy below is engineering's best effort and is not legal wording.**
/// §18.2 calls for a standalone CMIA authorization — 14-point type, separate
/// from all other language, its own signature — drafted by counsel, and it must
/// replace this before any real student sees it. What this type does provide is
/// the *structure* those requirements need: a distinct affirmative act, recorded
/// with a timestamp and a version, defaulting to off.
public struct MemoryConsent: Codable, Sendable, Equatable {
    /// Bumped when the disclosure changes. A consent recorded against old wording
    /// is not consent to new wording, and this is what lets that be detected
    /// rather than assumed.
    public static let currentVersion = "memory-v1"

    /// `consents.doc_type` on the server. Must match `MEMORY_CONSENT_DOC_TYPE`
    /// in `supabase/functions/coach/memory.ts`.
    public static let remoteDocType = "memory"

    public let isGranted: Bool
    public let grantedAt: Date?
    public let version: String

    public static let notGranted = MemoryConsent(isGranted: false, grantedAt: nil, version: currentVersion)

    public init(isGranted: Bool, grantedAt: Date?, version: String = MemoryConsent.currentVersion) {
        self.isGranted = isGranted
        self.grantedAt = grantedAt
        self.version = version
    }

    public static func granted(at date: Date) -> MemoryConsent {
        MemoryConsent(isGranted: true, grantedAt: date, version: currentVersion)
    }

    /// The only question callers should ask.
    ///
    /// Consent recorded against a superseded disclosure does not count. It is
    /// cheaper to ask again than to argue later that someone agreed to wording
    /// they were never shown.
    public var permitsRemoteMemory: Bool {
        isGranted && version == Self.currentVersion
    }
}

/// The disclosure a student reads before agreeing. Kept here, next to the policy,
/// so it is versioned with it rather than drifting inside a view.
public enum MemoryConsentCopy {
    public static let title = "Let C.A.L remember our conversations?"

    /// Written to be refusable. A disclosure that reads like a feature pitch is
    /// not really asking.
    public static let body = """
    C.A.L works without this. Your practices, journal and history all stay on \
    this phone either way, and you can use C.A.L exactly as you have been.

    If you say yes, what you type in Chat is sent to our server and kept there, \
    linked to your account, so C.A.L can refer back to it in a later conversation. \
    That is a copy of what you have written living somewhere other than your \
    phone.

    You can turn this off at any time, and you can delete everything C.A.L has \
    kept. Turning it off stops anything new being kept.
    """

    /// Named separately because MHMDA wants collection and sharing consented to
    /// separately. We do not share, and saying so plainly is the honest way to
    /// answer a question the student has every reason to ask.
    public static let sharingNote = """
    We do not sell this or share it with advertisers or analytics companies. \
    It is processed by the AI provider that generates C.A.L's replies, and by \
    nobody else.
    """

    public static let acceptTitle = "Yes, remember our conversations"
    public static let declineTitle = "No, keep everything on my phone"
}
