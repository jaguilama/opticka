classdef eyelinkManager < optickaCore
	%UNTITLED Summary of this class goes here
	%   Detailed explanation goes here
	
	properties
		screen = []
		defaults = struct()
		isDummy = false
		enableCallbacks = false
		verbose = true
	end
	
	properties (SetAccess = private, GetAccess = public)
		x = []
		y = []
		version = ''
		silentMode = false
		isConnected = false
		isRecording = false
		eyeUsed = -1
		currentEvent = []
		error = []
	end
	
	properties (SetAccess = private, GetAccess = private)
		%> allowed properties passed to object upon construction
		allowedProperties = 'name|verbose|isDummy|enableCallbacks'
	end
	
	methods
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function obj = eyelinkManager(varargin)
			if nargin>0
				obj.parseArgs(varargin,obj.allowedProperties);
			end
			obj.defaults = EyelinkInitDefaults();
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function initialise(obj,sM)
			if exist('sM','var')
				obj.screen=sM;
			else
				warning('Cannot initialise without a PTB screen')
				return
			end
			
			[result,dummy] = EyelinkInit(obj.isDummy,1);
			
			obj.isConnected = logical(result);
			obj.isDummy = logical(dummy);
			if obj.screen.isOpen == true
				obj.defaults = EyelinkInitDefaults(obj.screen.win);
			end
			[~, obj.version] = Eyelink('GetTrackerVersion');
			obj.salutation(['Running on a ' obj.version]);
			Eyelink('Command', 'link_sample_data = LEFT,RIGHT,GAZE,AREA');
			
			% open file to record data to
			if obj.isConnected == true
				Eyelink('Openfile', 'demo.edf');
				obj.isRecording = true;
			end
			
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function setup(obj)
			if obj.isConnected
				% Calibrate the eye tracker
				trackerSetup(obj);
				%driftCorrection(obj);
				checkEye(obj);
				
			end
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function trackerSetup(obj)
			if obj.isConnected
				% do a final check of calibration using driftcorrection
				EyelinkDoTrackerSetup(obj.defaults);
			end
		end
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function driftCorrection(obj)
			if obj.isConnected
				% do a final check of calibration using driftcorrection
				EyelinkDoDriftCorrection(obj.defaults);
			end
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function error = checkRecording(obj)
			if obj.isConnected
				error=Eyelink('CheckRecording');
			else
				error = -100;
			end
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function eyeUsed = checkEye(obj)
			if obj.isConnected
				obj.eyeUsed = Eyelink('EyeAvailable'); % get eye that's tracked
				if obj.eyeUsed == obj.defaults.BINOCULAR; % if both eyes are tracked
					obj.eyeUsed = obj.defaults.LEFT_EYE; % use left eye
				end
				eyeUsed = obj.eyeUsed;
			else
				obj.eyeUsed = -1;
				eyeUsed = obj.eyeUsed;
			end
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function close(obj)
			try
				Eyelink('StopRecording');
				obj.isRecording = false;
				Eyelink('CloseFile');
				try
					obj.salutation('Close Method',sprintf('Receiving data file %s', 'demo.edf'));
					status=Eyelink('ReceiveFile');
					if status > 0
						obj.salutation('Close Method',sprintf('ReceiveFile status %d', status));
					end
					if 2==exist('demo.edf', 'file')
						obj.salutation('Close Method',sprintf('Data file ''%s'' can be found in ''%s''', 'demo.edf', pwd));
					end
				catch ME
					obj.salutation('Close Method',sprintf('Problem receiving data file ''%s''', 'demo.edf'));
					rethrow(ME);
				end
				Eyelink('Shutdown');
			catch ME
				obj.salutation('Close Method','Couldn''t stop recording, forcing shutdown...',true)
				obj.isRecording = false;
				Eyelink('Shutdown');
				obj.error = ME;
				obj.salutation(ME.message);
			end
			obj.isConnected = false;
			obj.isDummy = false;
			obj.isRecording = false;
			obj.eyeUsed = -1;
			obj.screen = [];
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function evt = getSample(obj)
			if obj.isConnected && Eyelink('NewFloatSampleAvailable') > 0
				% get the sample in the form of an event structure
				evt = Eyelink('NewestFloatSample');
			else
				evt = [];
			end
		end
		
		% ===================================================================
		%> @brief 
		%>
		% ===================================================================
		function runDemo(obj)
			stopkey=KbName('space');
			try
				s = screenManager();
				o = dotsStimulus();
				s.screen = 1;
				open(s)
				setup(o,s);
				
				ListenChar(2);
				initialise(obj,s);
				setup(obj);
			
				Eyelink('StartRecording');
				WaitSecs(0.1);
				Eyelink('Message', 'SYNCTIME');
				while 1
					err = checkRecording(obj);
					if(err~=0); break; end;
						
					[~, ~, keyCode] = KbCheck;
					if keyCode(stopkey); break;	end;
					
					draw(o);
					drawGrid(s);
					drawFixationPoint(s);
					
					evt = getSample(obj);
					
					if ~isempty(evt)
						x = evt.gx(obj.eyeUsed+1); % +1 as we're accessing MATLAB array
						y = evt.gy(obj.eyeUsed+1);
						Screen('DrawDots', s.win, [x y], 4, rand(3,1), [], 2)
						txt = sprintf('X = %g | Y = %g', x, y);
						Screen('DrawText', s.win, txt, 10, 10);
					end
					
					animate(o);
					
					Screen('Flip',s.win);
					
				end
				ListenChar(0);
				close(s);
				close(obj);
				
			catch ME
				obj.salutation('\nrunDemo ERROR!!!\n')
				Eyelink('Shutdown');
				ListenChar(0);
				close(s);
				sca;
				close(obj);
				obj.error = ME;
				obj.salutation(ME.message);
				rethrow(ME);
			end
			
		end
		
	end
	
end
