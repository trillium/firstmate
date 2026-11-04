before: cleanup succeeds -> "landed" (even if PR OPEN)
after:  forge read state==MERGED -> cleanup + "landed"; OPEN -> no cleanup, "open, awaiting merge"
