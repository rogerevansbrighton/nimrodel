%   File:       swiprolog.pl
%   Purpose:    SWI prolog loader for complete application
%   Author:     Roger Evans
%   Version:    1.0
%   Date:       21/12/2013
%
%   (c) Copyright 2013, University of Brighton

% SWI prolog-specific startup
% input from command line args:
% 	swipl -q -f swiprolog.pl -g main -t halt -- <args>
% input from standard input:
%	swipl -q -f swiprolog.pl -g main -t halt
% NB: currently (swi v6.6.1, under Windows 7) it appears swipl falls over 
% 	  if you redirect just stdin to a file or pipeline. But if you also redirect 
% 	  stdout it works.

use(library(pio)).
use(library(filesex)).

% check/set envirionment variable
nimrodel_env(EnvName, _Value) :-
	% already set
	getenv(EnvName, _V), !.
nimrodel_env(EnvName, Value) :-
	% set to given value, but expand embedded env vars firs
	expand_file_name(Value, [Value2|_]),
	setenv(EnvName, Value2).

% add directory to path if not already present
% borrowed from lib jpl - added expand_file_name call
nimrodel_add_search_path(Path, Dir) :-
	expand_file_name(Dir, [Dir2|_]),
	(	getenv(Path, Old)
	->	(	current_prolog_flag(windows, true)
		->	Sep = (;)
		;	Sep = (:)
		),
		(	atomic_list_concat(Current, Sep, Old),
			memberchk(Dir2, Current)
			->      true                    % already present
			;
			atomic_list_concat([Old, Sep, Dir2], New),
			setenv(Path, New)
		)
	;
		setenv(Path, Dir2)
	).

% set environment variables that we will be interpreting
setup_nimrodel_env :-
	prompt(_P, ''),
	working_directory(D, D),
	nimrodel_env('ELFAPP', D),
	nimrodel_env('ELFROOT', '$ELFAPP/3rd-party/elf'),
	nimrodel_env('ELF', '$ELFROOT/elf'),
	nimrodel_env('DATR', '$ELF/datr').

% only needed when loading from precompiled state
nimrodel_do_runtime_setup :-
	setup_nimrodel_env,
	nimrodel_add_search_path('CLASSPATH', '$ELFROOT/opennlp/lib/opennlp-tools-1.5.3.jar').

:- setup_nimrodel_env.

% load datr (and patches) if required - assert quiet flag first to prevent printing of messages
:- clause(datr_compile(_X),_Y); 
		assert(datr_flag(quiet)),
		consult('$DATR/swiprolog.pl'), 
		consult('datr_patches.pl').

% load the ELF app and the prolog api
:- dynamic 'nimrodel.PARAMS/4'.
:- datr_compile('$ELFAPP/app.dtr').
:- compile('$ELFAPP/api.pl').	
	

% invocation as prolog 'application' 


% ----------------------------------------------------------------------
% mode 1: text directly on command line
% ----------------------------------------------------------------------

% main/0, main/1
% invoke DATR app.MAIN with user supplied args (main/1), or args from command line (main/0)
main :- swi_get_arglist(L), main(L).
main(L) :- datr_query('app.MAIN', [arglist|L], _V), halt.	


% ----------------------------------------------------------------------
% mode 2: multiple filenames on command line, one output
% ----------------------------------------------------------------------

% on_files/0, on_files/1
% invoke DATR app.MAIN on each file in the list
on_files :- swi_get_arglist(L), on_files(L).
on_files(Files) :-
	forall(member(File,Files), on_file(File)),
	halt.

% on_file/1
% run DATR app.MAIN on a single file, for now printing the
% results to stdout
on_file(File) :-
	% EYK: I don't understand this magic from
	% http://stackoverflow.com/a/11107786
	% to slurp a file
	once(phrase_from_file(all(Chars), File)),
	string_codes(Str, Chars),
	datr_query('app.MAIN', [arglist, '-title', File, Str|[]], _V).

% ----------------------------------------------------------------------
% mode 3 and 4: input/output directory on command line
% 3. recursive traversal, one output file per input file
% 4. recursive traversal, no output (just timing)
% ----------------------------------------------------------------------

% traverse_dir/0, traverse_dir/1, traverse_dir/2
% walk a directory, and invoke DATR app.MAIN on each file
% within that dir (recursive search)
%
% save the result with a mirror filename in the output dir
traverse_dir :- swi_get_arglist(L), traverse_dir(L).
traverse_dir([A1, A2|As]) :-
	% last two args are dir in and out; any before are flags
	reverse([A1, A2| As], [DirOut, DirIn | RevFlags]),
	reverse(RevFlags, Flags),
	traverse_dir(Flags, DirIn, DirOut), halt.
traverse_dir(_) :-
	write('Usage: <prognam> [nimrodel-arg...] input-dir output-dir'), nl, halt.
traverse_dir(Flags, DirIn, DirOut) :- on_dir(DirIn, DirOut, query_and_jsonify(Flags)).

% time_dir/0
% walk a directory, and invoke DATR app.MAIN on each file
% within that dir (recursive search),
% time each DATR call and printing timing information to stdout
%
% save the result with a mirror filename in the output dir
time_dir :- swi_get_arglist([DirIn, DirOut]), !, time_dir(DirIn, DirOut), halt.
time_dir :- write('Usage: <prognam> input-dir output-dir'), nl, halt.
time_dir(DirIn, DirOut) :- on_dir(DirIn, DirOut, time_query).

% on_dir/3
%
% given an input directory, an output directory, and a job (/2)
% apply that job to every input/output file name pair we can get
% by walking the directory and mirroring any input filename into
% an equivalent output file name
%
% We also create any intermediary output directories
% along the way
on_dir(DirIn, DirOut, Job) :-
	write('walking dir '), write(DirIn), write(' (->'), write(DirOut), write(')'), nl,
	directory_file_path(DirIn, '*', DirInPatt),
	expand_file_name(DirInPatt, Files),
	make_directory_path(DirOut),
	forall(member(File, Files), on_dir_item( File, DirOut, Job)).

% on_dir_item
on_dir_item('.', _, _).
on_dir_item('..', _, _).
on_dir_item(File, DirOut, Job) :-
	directory_file_path(_, Item, File),
	%directory_file_path(DirIn, Item, ItemIn),
	directory_file_path(DirOut, Item, ItemOut),
	on_dir_item_exp(File, ItemOut, Job).

% on_dir_item with the item expanded to be relative
on_dir_item_exp(ItemIn, ItemOut, Job) :-
	exists_file(ItemIn),
	call(Job, ItemIn, ItemOut).
on_dir_item_exp(ItemIn, ItemOut, Job) :-
	exists_directory(ItemIn),
	on_dir(ItemIn, ItemOut, Job).

% ----------------------------------------------------------------------
% mode 5: one input file plus iterations; timing only
% ----------------------------------------------------------------------

% time_repeat_on_file/0, time_repeat_on_file/2
% repeatedly run a query on a file
time_repeat_on_file :- swi_get_arglist([ItersStr, File]),
	atom_to_term(ItersStr, Iters, []),
	integer(Iters),
	time_repeat_on_file(Iters, File).
time_repeat_on_file :- write('Usage: <prognam> iterations file'), nl, halt.
time_repeat_on_file(Iters, File) :-
	once(phrase_from_file(all(Chars), File)),
	string_codes(Str, Chars),
	time_repeat_on_str(File, Iters, Str).

time_repeat_on_str(_, N, _) :- N =< 0.
time_repeat_on_str(File, N, Str) :-
	time_query_str(File, Str),
	Nm1 is N-1,
	time_repeat_on_str(File, Nm1, Str).

% ----------------------------------------------------------------------
% mode 6: save state
%
% to speed up load time dump the save state to a local cache
% ----------------------------------------------------------------------

save_state :- swi_get_arglist(L), save_state(L).
save_state([File]) :-
	qsave_program(File, [stand_alone(false), goal(dispatch)]).

% treat first arg as command
dispatch :- swi_get_arglist(L), dispatch(L).
dispatch([Cmd|L]) :-
	setup_nimrodel_env,
	nimrodel_do_runtime_setup,
	call(Cmd, L), halt.
dispatch(_) :-
	write('Usage: <prognam> cmd [arg]..'), nl, halt.

% ----------------------------------------------------------------------
% core tasks
% ----------------------------------------------------------------------

% trivial example of a directory traversal job
simple_job(Args, In, Out) :-
	write('JOB '), write(Args), write(' '),
	write(In), write(' > '), write(Out),
	nl.

% query_and_jsonify/2
% read from input filename and write query result to output filename
query_and_jsonify(Args, In, Out) :-
	write(In), nl,
	once(phrase_from_file(all(Chars), In)),
	string_codes(Str, Chars),
	query_and_jsonify_str(Args, Str, Out).
query_and_jsonify_str(_, Str, _) :- is_whitespace_only(Str).
query_and_jsonify_str(Args, Str, Out) :-
	append([arglist1|Args], [Str], DatrPath),
	datr_query('app.MAIN', DatrPath, Vs),
	open(Out,write,OutStream),
	forall(member(V,Vs), write(OutStream, V)),
	close(OutStream).

% time_query/2
% read from input filename and time the datr query
% without writing any other output
time_query(In, _) :-
	once(phrase_from_file(all(Chars), In)),
	string_codes(Str, Chars),
	time_query_str(In, Str).
time_query_str(_, Str) :- is_whitespace_only(Str).
time_query_str(In, Str) :-
	Keys = [atoms, functors, clauses, globalused, trailused, heapused],
	statistics(cputime, TimeBefore),
	time(datr_query('app.MAIN', [arglist1, '-format','raw',Str|[]], _)),
	garbage_collect_atoms,
	garbage_collect,
	statistics(cputime, TimeAfter),
	file_base_name(In, InBasename),
	write(InBasename), write('\t'),
	format('~3f\t', [TimeAfter - TimeBefore]),
	forall(member(Key, Keys), write_stat(Key)),
	nl,
	statistics.

write_stat(Key) :-
	statistics(Key, Val),
	%write(Key), write(': '), write(Val), nl.
	write(Val), write('\t').

write_listing(Dir) :-
	make_directory_path(Dir),
	get_time(Stamp),
	format_time(atom(StampStr), '%FT%H%M%S', Stamp),
	directory_file_path(Dir, StampStr, ListingsFile),
	open(ListingsFile,write,OutStream),
	with_output_to(OutStream, listing),
	close(OutStream).


% ----------------------------------------------------------------------
% file/string manipulation
% ----------------------------------------------------------------------

% force a lazy list
all([])     --> [].
all([L|Ls]) --> [L], all(Ls).

% is_whitespace_only/1
is_whitespace_only(Str) :-
	normalize_space(string(NormStr), Str),
	string_length(NormStr, 0).

% ----------------------------------------------------------------------
% command line arguments
% ----------------------------------------------------------------------

% swi_get_arglist/1
% return all args following '--' from command line 
% since swi 6.6.1, just return all the args (others have been stripped already)

swi_get_arglist(L) :-
	current_prolog_flag(argv, L1),
	current_prolog_flag(version, V),
	( V > 60600 -> L = L1 ; swi_get_user_args(L1, L) ).

swi_get_user_args(['--'|L],L) :- !.
swi_get_user_args([_H|T],L) :- swi_get_user_args(T, L).
swi_get_user_args([],[]).
