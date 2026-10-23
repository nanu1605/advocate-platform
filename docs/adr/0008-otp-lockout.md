# 0008 — Wrong-OTP lockout

Status: accepted (founder delegated the decision, 24 Oct 2026)

## Context
Spec §15.2: "Lockout after 5 wrong codes." Phone OTPs are generated and checked by Supabase Auth. Our Send-SMS
hook sees each code when it is sent, but no hook sees a failed verification, and Supabase does not count failures
per number. The verify endpoint (`POST /auth/v1/verify`) is public behind the anon key, so a counter in our API
would only bind our own app: an attacker would call Supabase directly.

## Decision
1. **In the app:** after 5 wrong codes the OTP screen discards the code, shows "Too many wrong codes. Request a new
   code." and disables Verify until a new code is sent (`_maxWrong` in `sign_in_screens.dart`). A new code replaces
   the old one in Supabase, so this is the spec's lockout for every real user.
2. **On the server**, with the limits Supabase does enforce:
   - phone OTP expiry 60 s (Supabase dashboard → Auth → Phone; set it when staging/prod are created);
   - `token_verifications` = 30 per 5 min per IP (`supabase/config.toml`, same on staging/prod). Not lower:
     Indian mobile carriers put many users behind one CGNAT address;
   - our Send-SMS hook: 3 codes per 10 min and 10 per day per number (spec §15.2).

## Consequences
- Residual risk: each code lives 60 s, so one IP gets at most 30 guesses per code, and a number gets at most 10
  codes a day. An attacker with N addresses guesses a 6-digit code with probability ≤ 10 × 30N / 10⁶ per day
  (0.03% for one address, about 3% for 100), and every code they trigger reaches the owner's phone.
- Revisit in the P3 security hardening and pentest (spec §17), or earlier if Supabase adds a failed-verification
  hook. The stronger fix then is verification through our API with sessions minted server-side.
