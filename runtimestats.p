 plot "runtimestats.dat" using 1:3 title 'cpu-auslastung' with lines, \
    "runtimestats.dat" using 1:2 title 'procs-ready-to-run' with lines, \
       "runtimestats.dat" using 1:4 title 'ibrowse' with lines, \
	  "runtimestats.dat" using 1:5 title 'subscriptions' with lines, \
	     "runtimestats.dat" using 1:6 title 'proceeded subs' with lines, \
		"runtimestats.dat" using 1:7 title 'memory' with lines
	     