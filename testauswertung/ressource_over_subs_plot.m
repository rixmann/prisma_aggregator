function ressource_over_subs_plot(ParentDir, DirNames, Ressource)
  figure;
  hold on;
  for TestName = DirNames'
    printf("Zu ladender Pfad: %s\n", [ParentDir , TestName, "/runtimestats.dat"]);
    Mat = resource_avg_over_subs(prepare_runtimestats(load([ParentDir , TestName, "/runtimestats.dat"])), Ressource); 
				#gset title TestName;
    plot(Mat(:,[1]), Mat(:,[2]));
  endfor
  hold off;
endfunction
