--  Amiga-style wildcard matching (milestone 85b) — the
--  MatchPatternNoCase analog, pure and syscall-free so commands,
--  the shell and tests all share one implementation.
--
--  Pattern syntax (case-insensitive throughout):
--    ?        any single character
--    *        any sequence (shorthand for #?)
--    #x       zero or more occurrences of the single item x
--             (x may be a literal, ?, %, an escaped char, or a
--             parenthesised group)
--    %        the empty string
--    (a|b|c)  any one of the alternatives
--    ~pat     negation: matches whatever pat does not
--    'x       literal x (escape; '' is a literal quote)
--  Everything else is a literal character.  Groups do not nest
--  (dos.library doesn't either); a bare '|' or ')' is literal.

package Akernel_User.Glob is

   --  True when Pattern contains at least one wildcard token.
   function Is_Pattern (Pattern : String) return Boolean;

   --  Anchored whole-string match: True when Name is entirely
   --  described by Pattern.  Malformed patterns (trailing escape,
   --  unterminated group, '#' at end) simply never match.
   function Match (Pattern, Name : String) return Boolean;

end Akernel_User.Glob;
