// Who is asking — established by the server, never by the caller.
//
// This file exists because of one sentence that has to stay true: a metadata
// filter is not access control when the client picks the filter value. Personal
// memory is filtered by profile id, so if that id came out of the request body,
// reading another student's mental-health history would be a matter of typing a
// different UUID. It therefore comes from a verified token or it does not come
// at all.
//
// Verification is delegated to the auth server rather than done here with the
// JWT secret. That costs one HTTP call per request and buys three things: no
// signing secret in this function, revocation and expiry honoured for free, and
// no hand-rolled JWT parsing — the category of code where subtle mistakes are
// invisible until they are catastrophic.

export interface VerifiedUser {
  id: string;
}

export interface IdentityOptions {
  supabaseUrl?: string;
  anonKey?: string;
  fetchImpl?: typeof fetch;
}

/// The signed-in user for this request, or `null`.
///
/// `null` is the normal, expected case: the MVP has no accounts, so almost every
/// request is anonymous. It means "no personal memory", never "fall back to
/// something". Callers must treat it as an absence of identity rather than as an
/// error, and must not substitute an id from anywhere else.
export async function verifyUser(
  request: Request,
  options: IdentityOptions = {},
): Promise<VerifiedUser | null> {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  if (!token) {
    console.log("identity: no bearer token — anonymous request");
    return null;
  }

  const supabaseUrl = options.supabaseUrl ?? Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = options.anonKey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!supabaseUrl || !anonKey) {
    // Loudly. A caller that sent a perfectly good token and got treated as
    // anonymous because the *server* was misconfigured is indistinguishable, from
    // the outside, from a caller who sent nothing — the request succeeds, the
    // reply is fine, and memory silently never engages. That cost a whole
    // debugging pass: the client was proven to be sending a token while the
    // function had no way to check it and said nothing.
    console.error(
      "identity: SUPABASE_URL or SUPABASE_ANON_KEY is unset, so a bearer token " +
        "cannot be verified and every request is anonymous",
    );
    return null;
  }

  // Clients that are not signed in send the anon key as the bearer token. It is
  // a valid JWT, so it must be rejected by identity rather than by luck: it
  // carries no user, and treating it as one would file every anonymous device's
  // memories under a single shared id.
  if (token === anonKey) {
    console.log("identity: bearer token is the anon key — anonymous request");
    return null;
  }

  const doFetch = options.fetchImpl ?? fetch;
  try {
    const response = await doFetch(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/user`, {
      headers: { "apikey": anonKey, "Authorization": `Bearer ${token}` },
    });
    if (!response.ok) {
      console.error(
        `identity: auth server rejected the token (${response.status}) — anonymous request`,
      );
      return null;
    }

    const user = await response.json();
    // A response without an id is not a user, whatever its status code was.
    if (typeof user?.id === "string" && user.id) {
      console.log("identity: verified");
      return { id: user.id };
    }
    console.error("identity: auth server returned no id — anonymous request");
    return null;
  } catch (error) {
    // Fails closed. An auth server that cannot be reached means nobody is
    // identified, which costs a signed-in student their memory for that turn —
    // and is the only acceptable direction for this particular failure.
    console.error("identity check failed, treating request as anonymous:", error);
    return null;
  }
}
