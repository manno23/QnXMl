let send ~owed ~pulse =
  if not !owed then 0
  else
    let rc = pulse () in
    if rc = 0 then owed := false;
    rc
