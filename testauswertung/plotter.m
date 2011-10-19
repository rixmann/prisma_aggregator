function RetVal = plotter(ParentDir, DirNames, Ressource)
  RessourceNames = {"time", "runque", "CPU usage", "httpc_overload", "Subscription count", "Processed Subscriptions/Second", "Memory usage", "Treshhold Window size"};
  Colors = {[0,0,1], [0,1,0], [1,0,1], [0,1,1], [0,0,0], [1,0,0]};
  figure;
  ylabel(cell2mat(RessourceNames(Ressource)))#, "fontsize", 15);
  xlabel("Subscriptions")#, "fontsize", 15);
#  set(gca, "fontsize", 14);
  grid();
  hold on;
  Color = 1;
  for TestName0 = DirNames
    TestName = cell2mat(TestName0);
				#    disp("Zu ladender Pfad:");
				#    disp([ParentDir , TestName , "/runtimestats.dat"]);
    RawMat = prepare_runtimestats(load([ParentDir, TestName, "/runtimestats.dat"]));
    Mat = resource_avg_over_subs(RawMat, Ressource); 
    TMat = prepare_teststats(load([ParentDir, TestName, "/teststats.dat"]));
				#Berechenen des Zeitpunkts, an dem der erste Fehler auftrat
    i = 1;
    while TMat([i],  [3]) == 0 && i < length(TMat(:, [1]))
      i = i + 1;
    endwhile
    TError = TMat([i - 1], [1]);
    if TError > RawMat([end], [1])
      TError = RawMat([end], [1]);
    endif
    SCountError = interp1(RawMat(:, [1]), RawMat(:, [5]), TError, 'nearest') * 100;
    Fmtstr = ["-", ";", TestName, ";"];
    plot(Mat(:,[1]), Mat(:,[2]), Fmtstr, 'color', cell2mat(Colors(mod(Color, 6) + 1)), 'linewidth', 2);
    text(SCountError, interp1(Mat(:, [1]), Mat(:, [2]), SCountError, 'nearest'), "Error", "color", cell2mat(Colors(mod(Color, 6) + 1)), "fontsize", 14);
    Color = Color + 1;
  endfor
  hold off;
  RetVal = 1;
endfunction
