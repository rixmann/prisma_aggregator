function NewMat = resource_avg_over_subs(OldMat, Ressource, TestName)
  start_sub_cnt = OldMat([1],[5]);
  i = 1;
  collector = [];
  while (length(OldMat) > i) && (OldMat([i], [5]) < start_sub_cnt + 10)
    collector = [OldMat([i], [Ressource]), collector];
    i = i + 1;
  endwhile
  if length(OldMat) <= i
    NewMat = [OldMat([i], [5]) * 100, mean(collector)];
  else
    NewMat = [OldMat([i-1], [5]) * 100, mean(collector); resource_avg_over_subs(OldMat([i-1:end], :), Ressource)];
  endif 
endfunction
