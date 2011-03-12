% ========================================================================
%> @brief LABJACK Connects and manages a LabJack U3-HV
%>
%> Connects and manages a LabJack U3-HV
%>
% ========================================================================
classdef opxOnline < handle
	properties
		type = 'launcher'
		eventStart = 257 %257 is any strobed event
		eventEnd = -255
		maxWait = 6000
		autoRun = 1
		isSlave = 0
		protocol = 'udp'
		rAddress = '127.0.0.1'
		rPort = 8998
		lAddress = '127.0.0.1'
		lPort = 9889
		pollTime = 0.5
		verbosity = 0
		%> sometimes we shouldn't cleanup connections on delete, e.g. when we pass this
		%> object to another matlab instance as we will close the wrong connections!!!
		cleanup = 1
		%> should we replot all data in the ui?
		replotFlag = 0
	end
	
	properties (SetAccess = private, GetAccess = public)
		masterPort = 11111
		slavePort = 11112
		conn %listen connection
		msconn %master slave connection
		spikes %hold the sorted spikes
		nRuns = 0
		totalRuns = 0
		trial = struct()
		parameters = struct()
		units = struct()
		stimulus
		tmpFile
		data
		error
	end
	
	properties (SetAccess = private, GetAccess = public, Transient = true)
		opxConn %> connection to the omniplex
		isSlaveConnected = 0
		isMasterConnected = 0
		h %GUI handles
	end
	
	properties (SetAccess = private, GetAccess = private)
		allowedProperties='^(type|eventStart|eventEnd|protocol|rPort|rAddress|verbosity|cleanup)$'
		slaveCommand
		masterCommand
		oldcv
	end
	
	%=======================================================================
	methods %------------------PUBLIC METHODS
	%=======================================================================
		
		% ===================================================================
		%> @brief Class constructor
		%>
		%> More detailed description of what the constructor does.
		%>
		%> @param args are passed as a structure of properties which is
		%> parsed.
		%> @return instance of class.
		% ===================================================================
		function obj = opxOnline(args)
			if nargin>0 && isstruct(args)
				fnames = fieldnames(args); %find our argument names
				for i=1:length(fnames);
					if regexp(fnames{i},obj.allowedProperties) %only set if allowed property
						obj.salutation(fnames{i},'Configuring setting in constructor');
						obj.(fnames{i})=args.(fnames{i}); %we set up the properies from the arguments as a structure
					end
				end
			end
			
			if strcmpi(obj.type,'master') || strcmpi(obj.type,'launcher')
				obj.isSlave = 0;
			end
			
			
			if ispc
				Screen('Preference', 'SuppressAllWarnings',1);
				Screen('Preference', 'Verbosity', 0);
				Screen('Preference', 'VisualDebugLevel',0);
				obj.masterCommand = '!matlab -nodesktop -nosplash -r "opxRunMaster" &';
				obj.slaveCommand = '!matlab -nodesktop -nosplash -nojvm -r "opxRunSlave" &';
			else
				obj.masterCommand = '!osascript -e ''tell application "Terminal"'' -e ''activate'' -e ''do script "matlab -nodesktop -nosplash -maci -r \"opxRunMaster\""'' -e ''end tell''';
				obj.slaveCommand = '!osascript -e ''tell application "Terminal"'' -e ''activate'' -e ''do script "matlab -nodesktop -nosplash -nojvm -maci -r \"opxRunSlave\""'' -e ''end tell''';
			end
			
			switch obj.type
				
				case 'master'
					
					obj.initializeUI;					
					obj.spawnSlave;
					
					if obj.isSlaveConnected == 0
						warning('Sorry, slave process failed to initialize!!!')
					end
					
					obj.initializeMaster;
					pause(0.1)
					
					if ispc
						p=fileparts(mfilename('fullpath'));
						dos([p filesep 'moveMatlab.exe']);
					elseif ismac
						p=fileparts(mfilename('fullpath'));
						unix(['osascript ' p filesep 'moveMatlab.applescript']);
					end
					
					obj.listenMaster;
					
				case 'slave'
					
					obj.initializeSlave;
					obj.listenSlave;
					
				case 'launcher'
					%we simply need to launch a new master and return
					eval(obj.masterCommand);
					
			end
		end
		
		% ===================================================================
		%> @brief listenMaster
		%>
		%>
		% ===================================================================
		function listenMaster(obj)
			
			fprintf('\nListening for opticka, and controlling slave!');
			loop = 1;
			runNext = '';
			
			if obj.msconn.checkStatus ~= 6 %are we a udp client to the slave?
				checkS = 1;
				while checkS < 10
					obj.msconn.close;
					pause(0.1)
					obj.msconn.open;
					if obj.msconn.checkStatus == 6;
						break
					end
					checkS = checkS + 1;
				end
			end
			
			if obj.conn.checkStatus('rconn') < 1;
				obj.conn.open;
			end
			
			while loop
				
				if ~rem(loop,10);x
					if isa(obj.stimulus,'runExperiment')
						set(obj.h.opxUIInfoBox,'String',['We have stimulus, nRuns= ' num2str(obj.totalRuns) ' | waiting for go...'])
					elseif obj.conn.checkStatus('conn') > 0
						set(obj.h.opxUIInfoBox,'String','Opticka has connected to us, waiting for stimulus!...');
					else
						set(obj.h.opxUIInfoBox,'String','Waiting for Opticka to (re)connect to us...');
					end
				end
				if ~rem(loop,40);fprintf('.');end
				if ~rem(loop,400);fprintf('\n');fprintf('growl');obj.msconn.write('--master growls--');end
				
				if obj.conn.checkData
					data = obj.conn.read(0);
					%data = regexprep(data,'\n','');
					fprintf('\n{opticka message:%s}',data);
					switch data
						
						case '--ping--'
							obj.conn.write('--ping--');
							obj.msconn.write('--ping--');
							fprintf('\nOpticka pinged us, we ping opticka and slave!');
							
						case '--readStimulus--'
							obj.stimulus = [];
							tloop = 1;
							while tloop < 10
								pause(0.3);
								if obj.conn.checkData
									pause(0.3);
									obj.stimulus=obj.conn.readVar;
									if isa(obj.stimulus,'runExperiment')
										fprintf('We have the stimulus from opticka, waiting for GO!');
										obj.totalRuns = obj.stimulus.task.nRuns;
										obj.msconn.write('--nRuns--');
										obj.msconn.write(uint32(obj.totalRuns));
									else
										fprintf('We have a stimulus from opticka, but it is malformed!');
										obj.stimulus = [];
									end
									break
								end
								tloop = tloop + 1;
							end
							
						case '--GO!--'
							if ~isempty(obj.stimulus)
								loop = 0;
								obj.msconn.write('--GO!--') %tell slave to run
								runNext = 'parseData';
								break
							end
							
						case '--eval--'
							tloop = 1;
							while tloop < 10
								pause(0.1);
								if obj.conn.checkData
									command = obj.msconn.read(0);
									fprintf('\nOpticka tells us to eval= %s\n',command);
									eval(command);
									break
								end
								tloop = tloop + 1;
							end
							
						case '--bark order--'
							obj.msconn.write('--obey me!--');
							fprintf('\nOpticka asked us to bark, we should comply!');
							
						case '--quit--'
							fprintf('\nOpticka asked us to quit, meanies!');
							obj.msconn.write('--quit--')
							loop = 0;
							break
							
						case '--exit--'
							fprintf('\nMy service is no longer required (sniff)...\n');
							eval('exit')
							break
							
						otherwise
							fprintf('Someone spoke, but what did they say?...')
					end
				end
				
				if obj.msconn.checkData
					fprintf('\n{slave message: ');
					data = obj.msconn.read(0);
					if iscell(data)
						for i = 1:length(data)
							fprintf('%s\t',data{i});
						end
						fprintf('}\n');
					else
						fprintf('%s}\n',data);
					end
				end
				
				if obj.msconn.checkStatus ~= 6 %are we a udp client?
					checkS = 1;
					while checkS < 10
						obj.msconn.close;
						pause(0.1)
						obj.msconn.open;
						if obj.msconn.checkStatus == 6;
							break
						end
						checkS = checkS + 1;
					end
				end
				
				if obj.conn.checkStatus ~= 12; %are we a TCP server?
					obj.conn.checkClient;
					if obj.conn.conn > 0
						fprintf('\nWe''ve opened a new connection to opticka...\n')
						obj.conn.write('--opened--');
						pause(0.2)
					end
				end
				
				if obj.checkKeys
					obj.msconn.write('--quit--')
					break
				end
				pause(0.1)
				loop = loop + 1;
			end %end of main while loop
			
			switch runNext
				case 'parseData'
					obj.parseData;
				otherwise
					fprintf('\nMaster is sleeping, use listenMaster to make me listen again...');
			end
			
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function listenSlave(obj)
			
			fprintf('\nHumble Slave is Eagerly Listening to Master\n');
			loop = 1;
			obj.totalRuns = 0; %we reset it waiting for new stimulus
			
			if obj.msconn.checkStatus < 1 %have we disconnected?
				checkS = 1;
				while checkS < 5
					obj.msconn.close; %lets reconnect
					pause(0.1)
					obj.msconn.open;
					if obj.msconn.checkStatus > 0;
						break
					end
					checkS = checkS + 1;
				end
			end
			
			while loop
				
				if ~rem(loop,40);fprintf('.');end
				if ~rem(loop,400);fprintf('\n');fprintf('quiver');obj.msconn.write('--abuse me do!--');end
				
				if obj.msconn.checkData
					data = obj.msconn.read(0);
					data = regexprep(data,'\n','');
					fprintf('\n{message:%s}',data);
					switch data
						
						case '--nRuns--'
							tloop = 1;
							while tloop < 10
								if obj.msconn.checkData
									tRun = double(obj.msconn.read(0,'uint32'));
									obj.totalRuns = tRun;
									fprintf('\nMaster send us number of runs: %d\n',obj.totalRuns);
									break
								end
								pause(0.1);
								tloop = tloop + 1;
							end
							
						case '--ping--'
							obj.msconn.write('--ping--');
							fprintf('\nMaster pinged us, we ping back!\n');
							
						case '--hello--'
							fprintf('\nThe master has spoken...\n');
							obj.msconn.write('--i bow--');
							
						case '--tmpFile--'
							tloop = 1;
							while tloop < 10
								pause(0.1);
								if obj.msconn.checkData
									obj.tmpFile = obj.msconn.read(0);
									fprintf('\nThe master tells me tmpFile= %s\n',obj.tmpFile);
									break
								end
								tloop = tloop + 1;
							end
							
						case '--eval--'
							tloop = 1;
							while tloop < 10
								pause(0.1);
								if obj.msconn.checkData
									command = obj.msconn.read(0);
									fprintf('\nThe master tells us to eval= %s\n',command);
									eval(command);
									break
								end
								tloop = tloop + 1;
							end
							
						case '--master growls--'
							fprintf('\nMaster growls, we should lick some boot...\n');
							
						case '--quit--'
							fprintf('\nMy service is no longer required (sniff)...\n');
							data = obj.msconn.read(1); %we flush out the remaining commands
							break
							
						case '--exit--'
							fprintf('\nMy service is no longer required (sniff)...\n');
							eval('exit');
							
						case '--GO!--'
							fprintf('\nTime to run, yay!\n')
							loop = 0;
							if obj.totalRuns > 0
								obj.collectData;
							end
							
						case '--obey me!--'
							fprintf('\nThe master has barked because of opticka...\n');
							obj.msconn.write('--i quiver before you and opticka--');
							
						otherwise
							fprintf('\nThe master has barked, but I understand not!...\n');
					end
				end
				if obj.msconn.checkStatus('conn') < 1 %have we disconnected?
					loop = 1;
					while loop < 10
						for i = 1:length(obj.msconn.connList)
							try %#ok<TRYNC>
								pnet(obj.msconn.connList(i), 'close');
							end
						end
						obj.msconn.open;
						if obj.msconn.checkStatus ~= 0; 
							break
						end
						pause(0.1);
						loop = loop + 1;
					end
				end
				if obj.checkKeys
					break
				end
				pause(0.2);
				loop = loop + 1;
			end
			fprintf('\nSlave is sleeping, use listenSlave to make me listen again...');		
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function parseData(obj)
			loop = 1;
			abort = 0;
			opx=[];
			fprintf('\n\n===Parse Data Loop Starting===\n')
			while loop
				
				if ~rem(loop,40);fprintf('.');end
				if ~rem(loop,400);fprintf('\n');fprintf('ParseData:');end
				
				if obj.conn.checkData
					data = obj.conn.read(0);
					data = regexprep(data,'\n','');
					fprintf('\n{opticka message:%s}',data);
					switch data
						
						case '--ping--'
							obj.conn.write('--ping--');
							obj.msconn.write('--ping--');
							fprintf('\nOpticka pinged us, we ping opticka and slave!');

						case '--abort--'
							obj.msconn.write('--abort--');
							fprintf('\nOpticka asks us to abort, tell slave to stop too!');
							pause(0.3);
							abort = 1;
					end
				end
				
				if obj.msconn.checkData
					data = obj.msconn.read(0);
					fprintf('\n{message:%s}',data);
					switch data
						
						case '--beforeRun--'
							fprintf('\nSlave is about to run the main collection loop...');
							load(obj.tmpFile);
							obj.units = opx.units;
							obj.parameters = opx.parameters;
							obj.data=parseOpxSpikes;
							obj.data.initialize(obj);
							obj.initializePlot;
							obj.plotData;
							clear opx
							
						case '--finishRun--'
							tloop = 1;
							while tloop < 10
								if obj.msconn.checkData
									obj.nRuns = double(obj.msconn.read(0,'uint32'));
									fprintf('\nThe slave has completed run %d\n',obj.nRuns);
									break
								end
								pause(0.1);
								tloop = tloop + 1;
							end
							load(obj.tmpFile);
							obj.trial = opx.trial;
							obj.data.parseNextRun(obj);
							obj.plotData;
							clear opx
							
						case '--finishAll--'
							load(obj.tmpFile);
							obj.trial = opx.trial;
							obj.plotData
							loop = 0;
							pause(0.2)
							save(obj.tmpFile,'obj');
							pause(0.2)
							abort = 1;
							
						case '--finishAbort--'
							load(obj.tmpFile);
							obj.trial = opx.trial;
							obj.plotData
							loop = 0;
							pause(0.2)
							save(obj.tmpFile,'obj');
							pause(0.2)
							abort = 1;
					end
				end
				if abort == 1;
					break
				end
			end
			obj.listenMaster
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function collectData(obj)
			tic
			abort=0;
			obj.nRuns = 0;
			
			status = obj.openPlexon;
			if status == -1
				abort = 1;
			end
			
			obj.getParameters;
			obj.getnUnits;
			
			obj.trial = struct;
			obj.nRuns=1;
			obj.saveData;
			obj.msconn.write('--beforeRun--');
			pause(0.1);
			toc
			try
				while obj.nRuns <= obj.totalRuns && abort < 1
					PL_TrialDefine(obj.opxConn, obj.eventStart, obj.eventEnd, 0, 0, 0, 0, [1,2,3,4,5,6],0,0);
					fprintf('\nWaiting for run: %i\n', obj.nRuns);
					[rn, trial, spike, analog, last] = PL_TrialStatus(obj.opxConn, 3, obj.maxWait); %wait until end of trial
					tic
					fprintf('rn: %i tr: %i sp: %i al: %i lst: %i\n',rn, trial, spike, analog, last);
					if last > 0
						[obj.trial(obj.nRuns).ne, obj.trial(obj.nRuns).eventList]  = PL_TrialEvents(obj.opxConn, 0, 0);
						[obj.trial(obj.nRuns).ns, obj.trial(obj.nRuns).spikeList]  = PL_TrialSpikes(obj.opxConn, 0, 0);
						
						obj.saveData;
						obj.msconn.write('--finishRun--');
						obj.msconn.write(uint32(obj.nRuns));
						
						obj.nRuns = obj.nRuns+1;
					end
					if obj.msconn.checkData
						command = obj.conn.read(0);
						switch command
							case '--abort--'
								fprintf('\nWe''ve been asked to abort\n')
								abort = 1;
								break
						end
					end
					if obj.checkKeys
						break
					end
					toc
				end
				obj.saveData; %final save of data
				if abort == 1
					obj.msconn.write('--finishAbort--');
				else
					obj.msconn.write('--finishAll--');
				end
				obj.msconn.write(uint32(obj.nRuns));
				% you need to call PL_Close(s) to close the connection
				% with the Plexon server
				obj.closePlexon;
				obj.listenSlave;
				
			catch ME
				obj.error = ME;
				fprintf('There was some error during data collection by slave!\n');
				fprintf('Error message: %s\n',obj.error.message);
				fprintf('Line: %d ',obj.error.stack.line);
				obj.nRuns = 0;
				obj.closePlexon;
				obj.listenSlave;
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function plotData(obj)
			if ~exist('oldcv','var');oldcv=1;end
			cv = get(obj.h.opxUICell,'Value');
			xmax = str2num(get(obj.h.opxUIEdit1,'String'));
			ymax = str2num(get(obj.h.opxUIEdit2,'String'));
			if isempty(xmax);xmax=2;end
			if isempty(ymax);ymax=10;end
			try
				if obj.replotFlag == 1 || (cv ~= oldcv)
					for i = 1:obj.data.nDisp
						data = obj.data.unit{cv}.raw{i};
						nt = obj.data.unit{cv}.trials{i};
						subplot(obj.data.yLength,obj.data.xLength,i,'Parent',obj.h.opxUIPanel)
						hist(data,40)
						title(['Cell: ' num2str(cv) ' | Trials: ' num2str(nt)]);
						axis([0 xmax 0 ymax]);
						h = findobj(gca,'Type','patch');
						set(h,'FaceColor','k','EdgeColor',[0.3 0.3 0.3])
					end
				else
					thisRun = obj.data.thisRun;
					index = obj.data.thisIndex;
					data = obj.data.unit{cv}.raw{index};
					nt = opx.data.unit{1}.trials{index};
					subplot(obj.data.yLength,obj.data.xLength,index,'Parent',obj.h.opxUIPanel)
					hist(data,40)
					title(['Cell: ' num2str(cv) ' | Run: ' num2str(thisRun) ' | Trials: ' num2str(nt)]);
					axis([0 xmax 0 ymax]);
					h = findobj(gca,'Type','patch');
					set(h,'FaceColor','b','EdgeColor','r')
				end
			end
			drawnow;
			obj.replotFlag = 0;
			oldcv=cv;
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function initializePlot(obj)
			if isstruct(obj.h) && ~ishandle(obj.h.uihandle)
				obj.initializeUI;
			end
			try
				s=cellstr(num2str((1:obj.units.totalCells)'));
				set(obj.h.opxUICell,'String', s);
				set(obj.h.opxUIAnalysisMethod,'Value',2);
				switch obj.stimulus.task.nVars
					case 0
						set(obj.h.opxUISelect1,'Enable','off')
						set(obj.h.opxUISelect2,'Enable','off')
						set(obj.h.opxUISelect3,'Enable','off')
						set(obj.h.opxUISelect1,'String','')
						set(obj.h.opxUISelect2,'String','')
						set(obj.h.opxUISelect3,'String','')
					case 1
						set(obj.h.opxUISelect1,'Enable','on')
						set(obj.h.opxUISelect2,'Enable','off')
						set(obj.h.opxUISelect3,'Enable','off')
						set(obj.h.opxUISelect1,'String',num2str(obj.stimulus.task.nVar(1).values'))
						set(obj.h.opxUISelect2,'String','')
						set(obj.h.opxUISelect3,'String','')
					case 2
						set(obj.h.opxUISelect1,'Enable','on')
						set(obj.h.opxUISelect2,'Enable','on')
						set(obj.h.opxUISelect3,'Enable','off')
						set(obj.h.opxUISelect1,'String',num2str(obj.stimulus.task.nVar(1).values'))
						set(obj.h.opxUISelect2,'String',num2str(obj.stimulus.task.nVar(2).values'))
						set(obj.h.opxUISelect3,'String',' ')
					case 3
						set(obj.h.opxUISelect1,'Enable','on')
						set(obj.h.opxUISelect2,'Enable','on')
						set(obj.h.opxUISelect3,'Enable','on')
						set(obj.h.opxUISelect1,'String',num2str(obj.stimulus.task.nVar(1).values'))
						set(obj.h.opxUISelect2,'String',num2str(obj.stimulus.task.nVar(2).values'))
						set(obj.h.opxUISelect3,'String',num2str(obj.stimulus.task.nVar(3).values'))
				end
				set(obj.h.opxUIEdit1,'String','')
				set(obj.h.opxUIEdit1,'String','')
				set(obj.h.opxUISelect1,'String','')
				subplot(obj.data.yLength,obj.data.xLength,1,'Parent',obj.h.opxUIPanel);
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function saveData(obj)
			opx.type = obj.type;
			opx.nRuns = obj.nRuns;
			opx.totalRuns = obj.totalRuns;
			opx.spikes = obj.spikes;
			opx.trial = obj.trial;
			opx.units = obj.units;
			opx.parameters = obj.parameters;
			opx.stimulus = obj.stimulus;
			opx.tmpFile = obj.tmpFile;
			save(obj.tmpFile,'opx');
		end
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function status=openPlexon(obj)
			status = -1;
			obj.opxConn = PL_InitClient(0);
			if obj.opxConn ~= 0
				status = 1;
			end
		end
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function closePlexon(obj)
			if exist('mexPlexOnline','file') && ~isempty(obj.opxConn) && obj.opxConn > 0
				PL_Close(obj.opxConn);
				obj.opxConn = [];
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function closeAll(obj)
			obj.closePlexon;
			if isa(obj.conn,'dataConnection')
				obj.conn.close;
			end
			if isa(obj.msconn,'dataConnection')
				obj.msconn.close;
			end
		end
	end %END METHODS
	
	%=======================================================================
	methods ( Access = private ) % PRIVATE METHODS
	%=======================================================================
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function getParameters(obj)
			if obj.opxConn>0
				pars = PL_GetPars(obj.opxConn);
				fprintf('Server Parameters:\n\n');
				fprintf('DSP channels: %.0f\n', pars(1));
				fprintf('Timestamp tick (in usec): %.0f\n', pars(2));
				fprintf('Number of points in waveform: %.0f\n', pars(3));
				fprintf('Number of points before threshold: %.0f\n', pars(4));
				fprintf('Maximum number of points in waveform: %.0f\n', pars(5));
				fprintf('Total number of A/D channels: %.0f\n', pars(6));
				fprintf('Number of enabled A/D channels: %.0f\n', pars(7));
				fprintf('A/D frequency (for continuous "slow" channels, Hz): %.0f\n', pars(8));
				fprintf('A/D frequency (for continuous "fast" channels, Hz): %.0f\n', pars(13));
				fprintf('Server polling interval (msec): %.0f\n', pars(9));
				obj.parameters.raw = pars;
				obj.parameters.channels = pars(1);
				obj.parameters.timestamp=pars(2);
				obj.parameters.timedivisor = 1e6 / obj.parameters.timestamp;
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function getnUnits(obj)
			if obj.opxConn>0
				obj.units.raw = PL_GetNumUnits(obj.opxConn);
				obj.units.activeChs = find(obj.units.raw > 0);
				obj.units.nCh = length(obj.units.activeChs);
				obj.units.nCells = obj.units.raw(obj.units.raw > 0);
				obj.units.totalCells = sum(obj.units.nCells);
				for i=1:obj.units.nCh
					if i==1
						obj.units.indexb{1}=1:obj.units.nCells(1);
						obj.units.index{1}=1:obj.units.nCells(1);
						obj.units.listb(1:obj.units.nCells(i))=i;
						obj.units.list{i}(1:obj.units.nCells(i))=i;
					else
						inc=sum(obj.units.nCells(1:i-1));
						obj.units.indexb{i}=(1:obj.units.nCells(i))+inc;
						obj.units.index{i}=1:obj.units.nCells(i);
						obj.units.listb(1:obj.units.nCells(i))=i;
						obj.units.list{i}(1:obj.units.nCells(i))=i;
					end
				end
				obj.units.chlist = [obj.units.list{:}];
				obj.units.celllist=[obj.units.index{:}];
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function reopenConnctions(obj)
			switch obj.type
				case 'master'
					try
						if obj.conn.checkStatus == 0
							obj.conn.closeAll;
							obj.msconn.closeAll;
							obj.msconn.open;
							obj.conn.open;
						end
					catch ME
						obj.error = ME;
					end
				case 'slave'
					try
						if obj.conn.checkStatus == 0
							obj.msconn.closeAll;
							obj.msconn.open;
						end
					catch ME
						obj.error = ME;
					end
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function initializeUI(obj)
			obj.h = [];
			uihandle=opx_ui; %our GUI file
			obj.h=guidata(uihandle);
			obj.h.uihandle = uihandle;
			setappdata(0,'opx',obj); %we stash our object in the root appdata store for retirieval from the UI
		end
		
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function initializeMaster(obj)
			fprintf('\nMaster is initializing, bow before my greatness...\n');
			obj.conn=dataConnection(struct('verbosity',obj.verbosity, 'rPort', obj.rPort, ...
				'lPort', obj.lPort, 'lAddress', obj.lAddress, 'rAddress', ... 
				obj.rAddress, 'protocol', 'tcp', 'autoOpen', 1, 'type', 'server'));
			if obj.conn.isOpen == 1
				fprintf('Master can listen for opticka...\n')
			else
				fprintf('Master is deaf...\n')
			end
			obj.tmpFile = [tempname,'.mat'];
			obj.msconn.write('--tmpFile--');
			obj.msconn.write(obj.tmpFile)
			fprintf('We tell slave to use tmpFile: %s\n', obj.tmpFile)
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function initializeSlave(obj)
			fprintf('\n===Slave is initializing, do with me what you will...===\n\n');
			obj.msconn=dataConnection(struct('verbosity', obj.verbosity, 'rPort', obj.masterPort, ...
					'lPort', obj.slavePort, 'rAddress', obj.lAddress, ... 
					'protocol',	obj.protocol,'autoOpen',1));
			if obj.msconn.isOpen == 1
				fprintf('Slave has opened its ears...\n')
			else
				fprintf('Slave is deaf...\n')
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function spawnSlave(obj)
			eval(obj.slaveCommand);
			obj.msconn=dataConnection(struct('verbosity',obj.verbosity, 'rPort',obj.slavePort,'lPort', ...
				obj.masterPort, 'rAddress', obj.lAddress,'protocol',obj.protocol,'autoOpen',1));
			if obj.msconn.isOpen == 1
				fprintf('Master can bark at slave...\n')
			else
				fprintf('Master cannot bark at slave...\n')
			end
			i=1;
			while i
				if i > 10
					i=0;
					break
				end
				obj.msconn.write('--hello--')
				pause(0.1)
				response = obj.msconn.read;
				if iscell(response);response=response{1};end
				if ~isempty(response) && ~isempty(regexpi(response, 'i bow'))
					fprintf('Slave knows who is boss...\n')
					obj.isSlaveConnected = 1;
					obj.isMasterConnected = 1;
					break
				end
				i=i+1;
			end
			
		end
		% ===================================================================
		%> @brief
		%>
		%>
		% ===================================================================
		function out=checkKeys(obj)
			out=0;
			[~,~,keyCode]=KbCheck;
			keyCode=KbName(keyCode);
			if ~isempty(keyCode)
				key=keyCode;
				if iscell(key);key=key{1};end
				if regexpi(key,'^esc')
					out=1;
				end
			end
		end
		
		% ===================================================================
		%> @brief Destructor
		%>
		%>
		% ===================================================================
		function delete(obj)
			if obj.cleanup == 1
				obj.salutation('opxOnline Delete Method','Cleaning up now...')
				obj.closeAll;
			else
				obj.salutation('opxOnline Delete Method','Closing (no cleanup)...')
			end
		end
		
		% ===================================================================
		%> @brief Prints messages dependent on verbosity
		%>
		%> Prints messages dependent on verbosity
		%> @param in the calling function
		%> @param message the message that needs printing to command window
		% ===================================================================
		function salutation(obj,in,message)
			if obj.verbosity > 0
				if ~exist('in','var')
					in = 'General Message';
				end
				if exist('message','var')
					fprintf([message ' | ' in '\n']);
				else
					fprintf(['\nHello from ' obj.name ' | opxOnline\n\n']);
				end
			end
		end
	end
	
	methods (Static)
		% ===================================================================
		%> @brief load object method
		%>
		%>
		% ===================================================================
		function lobj=loadobj(in)
			fprintf('Loading opxOnline object...\n')
			in.cleanup=0;
			if isa(in.conn,'dataConnection')
				in.conn.cleanup=0;
			end
			if isa(in.conn,'dataConnection')
				in.msconn.cleanup=0;
			end
			lobj=in;
		end
	end
end

