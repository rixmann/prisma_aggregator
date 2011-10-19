function NewMat = prepare_teststats(OldMat)
  i = 1;
while (OldMat([i],[2]) == 0) && (OldMat([i],[3]) == 0)
			       i = i + 1;
endwhile
time_offset = OldMat([i], [1]);
NewMat = OldMat([i:end], :)';
  time_vector = NewMat([1], :) - time_offset;
  NewMat = [time_vector; NewMat([2:end], :)]';
endfunction
