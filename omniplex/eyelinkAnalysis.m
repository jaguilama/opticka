% ========================================================================
%> @brief eyelinkAnalysis offers a set of methods to load, parse & plot raw EDF files. It
%> understands opticka trials so can parse eye data and plot it for trial groups. You
%> can also manually find microsaccades, and perform ROI/TOI filtering on the eye
%> movements.
% ========================================================================
classdef eyelinkAnalysis < analysisCore
% eyelinkAnalysis offers a set of methods to load, parse & plot raw EDF files.
	properties
		%> file name
		file@char									= ''
		%> directory
		dir@char										= ''
		%> the EDF message name to start measuring stimulus presentation
		rtStartMessage@char						= 'END_FIX'
		%> EDF message name to end the stimulus presentation
		rtEndMessage@char							= 'END_RT'
		%> the temporary experiement structure which contains the eyePos recorded from opticka
		tS@struct
		%> region of interest?
		ROI@double									= [ ]
		%> time of interest?
		TOI@double									= [ ]
		%> verbose output?
		verbose										= false
		%> minimum saccade distance in degrees
		minSaccadeDistance@double				= 0.99
		%> relative velocity threshold
		VFAC@double									= 5
		%> minimum saccade duration
		MINDUR@double								= 2  %equivalent to 6 msec at 500Hz sampling rate  (cf E&R 2006)
	end
	
	properties (Hidden = true)
		%occasionally we have some trials in the EDF not in the plx, this prunes them out
		trialsToPrune@double						= []
		%> these are used for spikes spike saccade time correlations
		rtLimits@double
		rtDivision@double
		%> trial list from the saved behavioural data, used to fix trial name bug old files
		trialOverride@struct
		%> screen resolution
		pixelsPerCm@double						= 32
		%> screen distance
		distance@double							= 57.3
		%> screen X center in pixels
		xCenter@double								= 640
		%> screen Y center in pixels
		yCenter@double								= 512
	end
	
	properties (SetAccess = private, GetAccess = public)
		%> have we parsed the EDF yet?
		isParsed@logical							= false
		%> sample rate
		sampleRate@double							= 250
		%> raw data
		raw@struct
		%> inidividual trials
		trials@struct
		%> eye data parsed into invdividual variables
		vars@struct
		%> the trial variable identifier, negative values were breakfix/incorrect trials
		trialList@double
		%> correct indices
		correct@struct								= struct()
		%> breakfix indices
		breakFix@struct							= struct()
		%> incorrect indices
		incorrect@struct							= struct()
		%> the display dimensions parsed from the EDF
		display@double
		%> for some early EDF files, there is no trial variable ID so we
		%> recreate it from the other saved data
		needOverride@logical						= false;
		%>ROI info
		ROIInfo
		%>TOI info
		TOIInfo
		%> does the trial variable list match the other saved data?
		validation@struct
	end
	
	properties (Dependent = true, SetAccess = private)
		%> pixels per degree calculated from pixelsPerCm and distance
		ppd
	end
	
	properties (SetAccess = private, GetAccess = private)
		%>57.3 bug override
		override573									= true;
		%> pixels per degree calculated from pixelsPerCm and distance (cache)
		ppd_
		%> allowed properties passed to object upon construction
		allowedProperties@char = 'file|dir|verbose|pixelsPerCm|distance|xCenter|yCenter|rtStartMessage|rtEndMessage|trialOverride|rtDivision|rtLimits|tS|ROI|TOI'
	end
	
	methods
		% ===================================================================
		%> @brief
		%>
		% ===================================================================
		function me = eyelinkAnalysis(varargin)
			if nargin == 0; varargin.name = ''; end
			me=me@analysisCore(varargin); %superclass constructor
			if nargin>0; me.parseArgs(varargin, me.allowedProperties); end
			if isempty(me.file) || isempty(me.dir)
				[me.file, me.dir] = uigetfile('*.edf','Load EDF File:');
			end
			me.ppd; %cache our initial ppd_
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function load(me,force)
			if ~exist('force','var');force=false;end
			if isempty(me.file)
				warning('No EDF file specified...');
				return
			end
			tic
			if isempty(me.raw) || force == true
				oldpath = pwd;
				cd(me.dir)
				me.raw = edfmex(me.file);
				if isnumeric(me.raw.RECORDINGS(1).sample_rate)
					me.sampleRate = double(me.raw.RECORDINGS(1).sample_rate);
				end
				fprintf('\n');
				cd(oldpath)
			end
			fprintf('<strong>�</strong> Loading Raw EDF Data took <strong>%g ms</strong>\n',round(toc*1000));
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parse(me)
			me.isParsed = false;
			tmain = tic;
			parseEvents(me);
			if ~isempty(me.trialsToPrune)
				me.pruneTrials(me.trialsToPrune);
			end
			parseAsVars(me);
			parseSecondaryEyePos(me);
			parseFixationPositions(me);
			parseROI(me);
			parseTOI(me);
			computeMicrosaccades(me);
			
			me.isParsed = true;
			
			fprintf('\tOverall Parsing of EDF Trials took <strong>%g ms</strong>\n',round(toc(tmain)*1000));
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseSaccades(me)
			parseROI(me);
			parseTOI(me);
			computeMicrosaccades(me);
		end
		
		% ===================================================================
		%> @brief prunetrials -- very rarely (n=1) we lose a trial strobe in the plexon data and
		%> thus when we try to align the plexon trial index and EDF trial index they are off-by-one,
		%> this function is used once the index of the trial is know to prune it out of the EDF data
		%> set and recalculate the indexes.
		%>
		%> @param
		%> @return
		% ===================================================================
		function pruneTrials(me,num)
			me.trials(num) = [];
			me.trialList(num) = [];
			me.correct.idx = find([me.trials.correct] == true);
			me.correct.saccTimes = [me.trials(me.correct.idx).firstSaccade];
			me.breakFix.idx = find([me.trials.breakFix] == true);
			me.breakFix.saccTimes = [me.trials(me.breakFix.idx).firstSaccade];
			me.incorrect.idx = find([me.trials.incorrect] == true);
			me.incorrect.saccTimes = [me.trials(me.incorrect.idx).firstSaccade];
			for i = num:length(me.trials)
				me.trials(i).correctedIndex = me.trials(i).correctedIndex - 1;
			end
			fprintf('Pruned %i trials from EDF trial data \n',num)
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function plot(me,select,type,seperateVars,name)
			if ~exist('select','var') || ~isnumeric(select); select = []; end
			if ~exist('type','var') || isempty(type); type = 'correct'; end
			if ~exist('seperateVars','var') || ~islogical(seperateVars); seperateVars = false; end
			if ~exist('name','var') || isempty(name)
				if isnumeric(select)
					if length(select) > 1
						name = [me.file ' | Select: ' num2str(length(select)) ' trials'];
					else
						name = [me.file ' | Select: ' num2str(select)];
					end
				end
			end
			if length(select) > 1;
				idx = select;
				idxInternal = false;
			else
				switch lower(type)
					case 'correct'
						idx = me.correct.idx;
					case 'breakfix'
						idx = me.breakFix.idx;
					case 'incorrect'
						idx = me.incorrect.idx;
				end
				idxInternal = true;
			end
			if seperateVars == true && isempty(select)
				vars = unique([me.trials(idx).id]);
				for j = vars
					me.plot(j,type,false);
					drawnow;
				end
				return
			end
			h=figure;
			set(gcf,'Color',[1 1 1],'Name',name);
			figpos(1,[1200 1200]);
			p = panel(h);
			p.fontsize = 12;
			p.margin = [10 10 10 20]; %left bottom right top
			p.pack('v',{2/3, []});
			q = p(1);
			q.margin = [20 20 10 25]; %left bottom right top
			q.pack(2,2);
			a = 1;
			stdex = [];
			meanx = [];
			meany = [];
			stdey = [];
			sacc = [];
			xvals = [];
			yvals = [];
			tvals = [];
			medx = [];
			medy = [];
			early = 0;
			mS = [];
			
			map = me.optimalColours(length(me.vars));
			
			if isempty(select)
				thisVarName = 'ALL VARS ';
			elseif length(select) > 1
				thisVarName = 'SELECTION ';
			else
				thisVarName = ['VAR' num2str(select) ' '];
			end
			
			maxv = 1;
			ppd = me.ppd;
			if ~isempty(me.TOI)
				t1 = me.TOI(1); t2 = me.TOI(2);
			else
				t1 = 0; t2 = 0.1;
			end
			
			for i = idx
				if idxInternal == true %we're using the eyelink index which includes incorrects
					f = i;
				else %we're using an external index which excludes incorrects
					f = find([me.trials.correctedIndex] == i);
				end
				if isempty(f); continue; end
				
				thisTrial = me.trials(f(1));
				
				if thisTrial.variable == 1010 %early edf files were broken, 1010 signifies this
					c = rand(1,3);
				else
					c = map(thisTrial.variable,:);
				end
				
				if isempty(select) || length(select) > 1 || ~isempty(intersect(select,thisTrial.variable));
				else continue
				end
				
				t = thisTrial.times / 1e3; %convert to seconds
				ix = find((t >= -0.4) & (t <= 0.8));
				t=t(ix);
				x = thisTrial.gx(ix) / ppd;
				y = thisTrial.gy(ix) / ppd;
				
				if min(x) < -20 || max(x) > 20 || min(y) < -20 || max(y) > 20
					x(x < -20) = -20;
					x(x > 20) = 20;
					y(y < -20) = -20;
					y(y > 20) = 20;
				end
				
				q(1,1).select();
				
				q(1,1).hold('on')
				plot(x, y,'k-o','Color',c,'MarkerSize',4,'MarkerEdgeColor',[0 0 0],...
					'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe);
				
				q(1,2).select();
				q(1,2).hold('on');
				plot(t,abs(x),'k-o','Color',c,'MarkerSize',4,'MarkerEdgeColor',[0 0 0],...
					'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe);
				plot(t,abs(y),'k-x','Color',c,'MarkerSize',4,'MarkerEdgeColor',[0 0 0],...
					'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe);
				maxv = max([maxv, max(abs(x)), max(abs(y))]) + 0.1;
				if isfield(thisTrial,'microSaccade') & ~isnan(thisTrial.microSaccades) & ~isempty(thisTrial.microSaccades)
					plot(thisTrial.microSaccades,-0.2,'yo','Color','y','MarkerSize',4,'MarkerEdgeColor',[0 0 0],...
					'MarkerFaceColor','y','UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe);
				end
				
				p(2).select();
				p(2).hold('on')
				for fix=1:length(thisTrial.fixations)
					f=thisTrial.fixations(fix);
					plot3([f.time/1e3 f.time/1e3+f.length/1e3],[f.gstx f.genx],[f.gsty f.geny],'k-o',...
						'LineWidth',1,'MarkerSize',5,'MarkerEdgeColor',[0 0 0],...
						'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe)
				end
				for sac=1:length(thisTrial.saccades)
					s=thisTrial.saccades(sac);
					plot3([s.time/1e3 s.time/1e3+s.length/1e3],[s.gstx s.genx],[s.gsty s.geny],'r-o',...
						'LineWidth',1.5,'MarkerSize',5,'MarkerEdgeColor',[1 0 0],...
						'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe)
				end
				p(2).margin = [50]; %left bottom right top
				
				idxt = find(t >= t1 & t <= t2);
				
				tvals{a} = t(idxt);
				xvals{a} = x(idxt);
				yvals{a} = y(idxt);
				if isfield(thisTrial,'firstSaccade') && thisTrial.firstSaccade > 0
					sacc = [sacc thisTrial.firstSaccade/1e3];
				end
				meanx = [meanx mean(x(idxt))];
				meany = [meany mean(y(idxt))];
				medx = [medx median(x(idxt))];
				medy = [medy median(y(idxt))];
				stdex = [stdex std(x(idxt))];
				stdey = [stdey std(y(idxt))];
				
				q(2,1).select();
				q(2,1).hold('on');
				plot(meanx(end), meany(end),'ko','Color',c,'MarkerSize',6,'MarkerEdgeColor',[0 0 0],...
					'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe);
				
				q(2,2).select();
				q(2,2).hold('on');
				plot3(meanx(end), meany(end),a,'ko','Color',c,'MarkerSize',6,'MarkerEdgeColor',[0 0 0],...
					'MarkerFaceColor',c,'UserData',[thisTrial.idx thisTrial.correctedIndex thisTrial.variable],'ButtonDownFcn', @clickMe);
				a = a + 1;
				
			end
			
			display = me.display / ppd;
			
			q(1,1).select();
			axis ij
			grid on
			box on
			axis(round([-display(1)/3 display(1)/3 -display(2)/3 display(2)/3]))
			%axis square
			title(q(1,1),[thisVarName upper(type) ': X vs. Y Eye Position'])
			xlabel(q(1,1),'X Deg')
			ylabel(q(1,1),'Y Deg')
			
			q(1,2).select();
			grid on
			box on
			axis tight;
			if maxv > 10; maxv = 10; end
			axis([-0.2 0.4 -0.2 maxv])
			ti=sprintf('ABS Mean/SD %g - %g s: X=%.2g / %.2g | Y=%.2g / %.2g', t1,t2,...
				mean(abs(meanx)), mean(abs(stdex)), ...
				mean(abs(meany)), mean(abs(stdey)));
			ti2 = sprintf('ABS Median/SD %g - %g s: X=%.2g / %.2g | Y=%.2g / %.2g', t1,t2,median(abs(medx)), median(abs(stdex)), ...
				median(abs(medy)), median(abs(stdey)));
			h=title(sprintf('X(square) & Y(cross) Position vs. Time\n%s\n%s', ti,ti2));
			set(h,'BackgroundColor',[1 1 1]);
			xlabel(q(1,2),'Time (s)')
			ylabel(q(1,2),'Degrees')
			
			p(2).select();
			grid on;
			box on;
			axis tight;
			axis([-0.1 0.4 -10 10 -10 10]);
			view([5 5]);
			xlabel(p(2),'Time (ms)')
			ylabel(p(2),'X Position')
			zlabel(p(2),'Y Position')
			mn = nanmean(sacc);
			md = nanmedian(sacc);
			[~,er] = stderr(sacc,'SD');
			h=title(sprintf('%s %s: Saccades (red) & Fixation (black) | First Saccade mean/median: %.2g / %.2g � %.2g SD [%.2g <> %.2g]',...
				thisVarName,upper(type),mn,md,er,min(sacc),max(sacc)));
			set(h,'BackgroundColor',[1 1 1]);
			
			q(2,1).select();
			axis ij
			grid on
			box on
			axis tight;
			axis([-1 1 -1 1])
			h=title(sprintf('X & Y %g-%gs MD/MN/STD: \nX : %.2g / %.2g / %.2g | Y : %.2g / %.2g / %.2g', ...
				t1,t2,mean(meanx), median(medx),mean(stdex),mean(meany),median(medy),mean(stdey)));
			set(h,'BackgroundColor',[1 1 1]);
			xlabel(q(2,1),'X Degrees')
			ylabel(q(2,1),'Y Degrees')
			
			q(2,2).select();
			grid on
			box on
			axis tight;
			axis([-1 1 -1 1])
			%axis square
			view(47,15)
			title(sprintf('%s %s Mean X & Y Pos %g-%g-s over time',thisVarName,upper(type),t1,t2))
			xlabel(q(2,2),'X Degrees')
			ylabel(q(2,2),'Y Degrees')
			zlabel(q(2,2),'Trial')
			
			p(2).margin = 20;
			
			assignin('base','xvals',xvals)
			assignin('base','yvals',yvals)
			
			function clickMe(src, ~)
				if ~exist('src','var')
					return
				end
				l=get(src,'LineWidth');
				if l > 1
					set(src,'Linewidth', 1, 'LineStyle', '-');
				else
					set(src,'LineWidth',2, 'LineStyle', ':');
				end
				ud = get(src,'UserData');
				if ~isempty(ud)
					disp(me.trials(ud(1)));
					disp(['TRIAL | CORRECTED | VAR = ' num2str(ud)]);
				end
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseROI(me)
			if isempty(me.ROI)
				disp('No ROI specified...')
				return
			end
			tROI = tic;
			ppd = me.ppd;
			fixationX = me.ROI(1);
			fixationY = me.ROI(2);
			fixationRadius = me.ROI(3);
			for i = 1:length(me.trials)
				me.ROIInfo(i).variable = me.trials(i).variable;
				me.ROIInfo(i).idx = i;
				me.ROIInfo(i).correctedIndex = me.trials(i).correctedIndex;
				me.ROIInfo(i).uuid = me.trials(i).uuid;
				me.ROIInfo(i).fixationX = fixationX;
				me.ROIInfo(i).fixationY = fixationY;
				me.ROIInfo(i).fixationRadius = fixationRadius;
				x = me.trials(i).gx / ppd;
				y = me.trials(i).gy  / ppd;
				times = me.trials(i).times / 1e3;
				idx = find(times > 0); % we only check ROI post 0 time
				times = times(idx);
				x = x(idx);
				y = y(idx);
				r = sqrt((x - fixationX).^2 + (y - fixationY).^2);
				within = find(r < fixationRadius);
				if any(within)
					me.ROIInfo(i).enteredROI = true;
				else
					me.ROIInfo(i).enteredROI = false;
				end
				me.trials(i).enteredROI = me.ROIInfo(i).enteredROI;
				me.ROIInfo(i).x = x;
				me.ROIInfo(i).y = y;
				me.ROIInfo(i).times = times;
				me.ROIInfo(i).r = r;
				me.ROIInfo(i).within = within;
				me.ROIInfo(i).correct = me.trials(i).correct;
				me.ROIInfo(i).breakFix = me.trials(i).breakFix;
				me.ROIInfo(i).incorrect = me.trials(i).incorrect;
			end
			fprintf('<strong>�</strong> Parsing eyelink region of interest (ROI) took <strong>%g ms</strong>\n', round(toc(tROI)*1000))
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseTOI(me)
			if isempty(me.TOI)
				disp('No TOI specified...')
				return
			end
			tTOI = tic;
			ppd = me.ppd;
			t1 = me.TOI(1);
			t2 = me.TOI(2);
			fixationX = me.TOI(3);
			fixationY = me.TOI(4);
			fixationRadius = me.TOI(5);
			for i = 1:length(me.trials)
				times = me.trials(i).times / 1e3;
				x = me.trials(i).gx / ppd;
				y = me.trials(i).gy  / ppd;
				
				idx = intersect(find(times>=t1), find(times<=t2));
				times = times(idx);
				x = x(idx);
				y = y(idx);
				
				r = sqrt((x - fixationX).^2 + (y - fixationY).^2);
				
				within = find(r <= fixationRadius);
				if length(within) == length(r)
					me.TOIInfo(i).isTOI = true;
				else
					me.TOIInfo(i).isTOI = false;
				end
				me.trials(i).isTOI = me.TOIInfo(i).isTOI;
				me.TOIInfo(i).variable = me.trials(i).variable;
				me.TOIInfo(i).idx = i;
				me.TOIInfo(i).correctedIndex = me.trials(i).correctedIndex;
				me.TOIInfo(i).uuid = me.trials(i).uuid;
				me.TOIInfo(i).t1 = t1;
				me.TOIInfo(i).t2 = t2;
				me.TOIInfo(i).fixationX = fixationX;
				me.TOIInfo(i).fixationY = fixationY;
				me.TOIInfo(i).fixationRadius = fixationRadius;
				me.TOIInfo(i).times = times;
				me.TOIInfo(i).x = x;
				me.TOIInfo(i).y = y;
				me.TOIInfo(i).r = r;
				me.TOIInfo(i).within = within;
				me.TOIInfo(i).correct = me.trials(i).correct;
				me.TOIInfo(i).breakFix = me.trials(i).breakFix;
				me.TOIInfo(i).incorrect = me.trials(i).incorrect;
			end
			fprintf('<strong>�</strong> Parsing eyelink time of interest (TOI) took <strong>%g ms</strong>\n', round(toc(tTOI)*1000))
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function plotROI(me)
			if ~isempty(me.ROIInfo)
				h=figure;figpos(1,[2000 1000]);set(h,'Color',[1 1 1],'Name',me.file);
				
				x1 = me.ROI(1) - me.ROI(3);
				x2 = me.ROI(1) + me.ROI(3);
				xmin = min([abs(x1), abs(x2)]);
				xmax = max([abs(x1), abs(x2)]);
				y1 = me.ROI(2) - me.ROI(3);
				y2 = me.ROI(2) + me.ROI(3);
				ymin = min([abs(y1), abs(y2)]);
				ymax = max([abs(y1), abs(y2)]);
				xp = [x1 x1 x2 x2];
				yp = [y1 y2 y2 y1];
				xpp = [xmin xmin xmax xmax];
				ypp = [ymin ymin ymax ymax];
				p=panel(h);
				p.pack(1,2);
				p.fontsize = 14;
				p.margin = [15 15 15 15];
				yes = logical([me.ROIInfo.enteredROI]);
				no = ~yes;
				yesROI = me.ROIInfo(yes);
				noROI	= me.ROIInfo(no);
				p(1,1).select();
				p(1,1).hold('on');
				patch(xp,yp,[1 1 0],'EdgeColor','none');
				p(1,2).select();
				p(1,2).hold('on');
				patch([0 1 1 0],xpp,[1 1 0],'EdgeColor','none');
				patch([0 1 1 0],ypp,[0.5 1 0],'EdgeColor','none');
				for i = 1:length(noROI)
					c = [0.7 0.7 0.7];
					if noROI(i).correct == true
						l = 'o-';
					else
						l = '.--';
					end
					t = noROI(i).times(noROI(i).times >= 0);
					x = noROI(i).x(noROI(i).times >= 0);
					y = noROI(i).y(noROI(i).times >= 0);
					if ~isempty(x)
						p(1,1).select();
						h = plot(x,y,l,'color',c,'MarkerFaceColor',c,'LineWidth',1);
						set(h,'UserData',[noROI(i).idx noROI(i).correctedIndex noROI(i).variable noROI(i).correct noROI(i).breakFix noROI(i).incorrect],'ButtonDownFcn', @clickMe);
						p(1,2).select();
						h = plot(t,abs(x),l,t,abs(y),l,'color',c,'MarkerFaceColor',c);
						set(h,'UserData',[noROI(i).idx noROI(i).correctedIndex noROI(i).variable noROI(i).correct noROI(i).breakFix noROI(i).incorrect],'ButtonDownFcn', @clickMe);
					end
				end
				for i = 1:length(yesROI)
					c = [0.7 0 0];
					if yesROI(i).correct == true
						l = 'o-';
					else
						l = '.--';
					end
					t = yesROI(i).times(yesROI(i).times >= 0);
					x = yesROI(i).x(yesROI(i).times >= 0);
					y = yesROI(i).y(yesROI(i).times >= 0);
					if ~isempty(x)
						p(1,1).select();
						h = plot(x,y,l,'color',c,'MarkerFaceColor',c);
						set(h,'UserData',[yesROI(i).idx yesROI(i).correctedIndex yesROI(i).variable yesROI(i).correct yesROI(i).breakFix yesROI(i).incorrect],'ButtonDownFcn', @clickMe);
						p(1,2).select();
						h = plot(t,abs(x),l,t,abs(y),l,'color',c,'MarkerFaceColor',c);
						set(h,'UserData',[yesROI(i).idx yesROI(i).correctedIndex yesROI(i).variable yesROI(i).correct yesROI(i).breakFix yesROI(i).incorrect],'ButtonDownFcn', @clickMe);
					end
				end
				hold off
				p(1,1).select();
				p(1,1).hold('off');
				box on
				grid on
				p(1,1).title(['ROI PLOT for ' num2str(me.ROI) ' (entered = ' num2str(sum(yes)) ' | did not = ' num2str(sum(no)) ')']);
				p(1,1).xlabel('X Position (degs)')
				p(1,1).ylabel('Y Position (degs)')
				axis square
				axis([-10 10 -10 10]);
				p(1,2).select();
				p(1,2).hold('off');
				box on
				grid on
				p(1,2).title(['ROI PLOT for ' num2str(me.ROI) ' (entered = ' num2str(sum(yes)) ' | did not = ' num2str(sum(no)) ')']);
				p(1,2).xlabel('Time(s)')
				p(1,2).ylabel('Absolute X/Y Position (degs)')
				axis square
				axis([0 0.5 0 10]);
			end
			function clickMe(src, ~)
				if ~exist('src','var')
					return
				end
				ud = get(src,'UserData');
				lw = get(src,'LineWidth');
				if lw < 1.8
					set(src,'LineWidth',2)
				else
					set(src,'LineWidth',1)
				end
				if ~isempty(ud)
					disp(['ROI Trial (idx correctidx var iscorrect isbreak isincorrect): ' num2str(ud)]);
				end
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function plotTOI(me)
			if isempty(me.TOIInfo)
				disp('No TOI parsed!!!')
				return
			end
			h=figure;figpos(1,[2000 1000]);set(h,'Color',[1 1 1],'Name',me.file);
			
			t1 = me.TOI(1);
			t2 = me.TOI(2);
			x1 = me.TOI(3) - me.TOI(5);
			x2 = me.TOI(3) + me.TOI(5);
			xmin = min([abs(x1), abs(x2)]);
			xmax = max([abs(x1), abs(x2)]);
			y1 = me.TOI(4) - me.TOI(5);
			y2 = me.TOI(4) + me.TOI(5);
			ymin = min([abs(y1), abs(y2)]);
			ymax = max([abs(y1), abs(y2)]);
			xp = [x1 x1 x2 x2];
			yp = [y1 y2 y2 y1];
			xpp = [xmin xmin xmax xmax];
			ypp = [ymin ymin ymax ymax];
			p=panel(h);
			p.pack(1,2);
			p.fontsize = 14;
			p.margin = [15 15 15 15];
			yes = logical([me.TOIInfo.isTOI]);
			no = ~yes;
			yesTOI = me.TOIInfo(yes);
			noTOI	= me.TOIInfo(no);
			p(1,1).select();
			p(1,1).hold('on');
			patch(xp,yp,[1 1 0],'EdgeColor','none');
			p(1,2).select();
			p(1,2).hold('on');
			patch([t1 t2 t2 t1],xpp,[1 1 0],'EdgeColor','none');
			patch([t1 t2 t2 t1],ypp,[0.5 1 0],'EdgeColor','none');
			for i = 1:length(noTOI)
				if noTOI(i).incorrect == true; continue; end
				c = [0.7 0.7 0.7];
				if noTOI(i).correct == true
					l = 'o-';
				else
					l = '.--';
				end
				t = noTOI(i).times;
				x = noTOI(i).x;
				y = noTOI(i).y;
				if ~isempty(x)
					p(1,1).select();
					h = plot(x,y,l,'color',c,'MarkerFaceColor',c,'LineWidth',1);
					set(h,'UserData',[noTOI(i).idx noTOI(i).correctedIndex noTOI(i).variable noTOI(i).correct noTOI(i).breakFix noTOI(i).incorrect],'ButtonDownFcn', @clickMe);
					p(1,2).select();
					h = plot(t,abs(x),l,t,abs(y),l,'color',c,'MarkerFaceColor',c);
					set(h,'UserData',[noTOI(i).idx noTOI(i).correctedIndex noTOI(i).variable noTOI(i).correct noTOI(i).breakFix noTOI(i).incorrect],'ButtonDownFcn', @clickMe);
				end
			end
			for i = 1:length(yesTOI)
				if yesTOI(i).incorrect == true; continue; end
				c = [0.7 0 0];
				if yesTOI(i).correct == true
					l = 'o-';
				else
					l = '.--';
				end
				t = yesTOI(i).times;
				x = yesTOI(i).x;
				y = yesTOI(i).y;
				if ~isempty(x)
					p(1,1).select();
					h = plot(x,y,l,'color',c,'MarkerFaceColor',c);
					set(h,'UserData',[yesTOI(i).idx yesTOI(i).correctedIndex yesTOI(i).variable yesTOI(i).correct yesTOI(i).breakFix yesTOI(i).incorrect],'ButtonDownFcn', @clickMe);
					p(1,2).select();
					h = plot(t,abs(x),l,t,abs(y),l,'color',c,'MarkerFaceColor',c);
					set(h,'UserData',[yesTOI(i).idx yesTOI(i).correctedIndex yesTOI(i).variable yesTOI(i).correct yesTOI(i).breakFix yesTOI(i).incorrect],'ButtonDownFcn', @clickMe);
				end
			end
			hold off
			p(1,1).select();
			p(1,1).hold('off');
			box on
			grid on
			p(1,1).title(['TOI PLOT for ' num2str(me.TOI) ' (yes = ' num2str(sum(yes)) ' || no = ' num2str(sum(no)) ')']);
			p(1,1).xlabel('X Position (degs)')
			p(1,1).ylabel('Y Position (degs)')
			axis([-4 4 -4 4]);
			axis square
			p(1,2).select();
			p(1,2).hold('off');
			box on
			grid on
			p(1,2).title(['TOI PLOT for ' num2str(me.TOI) ' (yes = ' num2str(sum(yes)) ' || no = ' num2str(sum(no)) ')']);
			p(1,2).xlabel('Time(s)')
			p(1,2).ylabel('Absolute X/Y Position (degs)')
			axis([t1 t2 0 4]);
			axis square
			
			function clickMe(src, ~)
				if ~exist('src','var')
					return
				end
				ud = get(src,'UserData');
				lw = get(src,'LineWidth');
				if lw < 1.8
					set(src,'LineWidth',2)
				else
					set(src,'LineWidth',1)
				end
				if ~isempty(ud)
					disp(['TOI Trial (idx correctidx var iscorrect isbreak isincorrect): ' num2str(ud)]);
				end
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function ppd = get.ppd(me)
			if me.distance == 57.3 && me.override573 == true
				ppd = round( me.pixelsPerCm * (67 / 57.3)); %set the pixels per degree, note this fixes some older files where 57.3 was entered instead of 67cm
			else
				ppd = round( me.pixelsPerCm * (me.distance / 57.3)); %set the pixels per degree
			end
			me.ppd_ = ppd;
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function fixVarNames(me)
			if me.needOverride == true
				if isempty(me.trialOverride)
					warning('No replacement trials available!!!')
					return
				end
				trials = me.trialOverride; %#ok<*PROP>
				if  max([me.trials.correctedIndex]) ~= length(trials)
					warning('TRIAL ID LENGTH MISMATCH!');
					return
				end
				a = 1;
				me.trialList = [];
				for j = 1:length(me.trials)
					if me.trials(j).incorrect ~= true
						if a <= length(trials) && me.trials(j).correctedIndex == trials(a).index
							me.trials(j).oldid = me.trials(j).variable;
							me.trials(j).variable = trials(a).variable;
							me.trialList(j) = me.trials(j).variable;
							if me.trials(j).breakFix == true
								me.trialList(j) = -[me.trialList(j)];
							end
							a = a + 1;
						end
					end
				end
				parseAsVars(me); %need to redo this now
				warning('---> Trial name override in place!!!')
			else
				me.trialOverride = struct();
			end
		end
		
	end%-------------------------END PUBLIC METHODS--------------------------------%
	
	%=======================================================================
	methods (Static = true) %------------------STATIC METHODS
	%=======================================================================
		% ===================================================================
		%> @brief we also collect eye position within the main PTB loop (sampled at every
		%> screen refresh) and this is a lower resolution backup of the eye position data if we
		%> need.
		%>
		%> @param
		%> @return
		% ===================================================================
		function plotSecondaryEyeLogs(tS)
			
			ifi = 0.013;
			tS = tS.eyePos;
			fn = fieldnames(tS);
			h=figure;
			set(gcf,'Color',[1 1 1]);
			figpos(1,[1200 1200]);
			p = panel(h);
			p.pack(2,2);
			a = 1;
			stdex = [];
			stdey = [];
			early = [];
			maxv = [];
			for i = 1:length(fn)-1
				if ~isempty(regexpi(fn{i},'^E')) && ~isempty(regexpi(fn{i+1},'^CC'))
					x = tS.(fn{i}).x;
					y = tS.(fn{i}).y;
					%if a < Inf%(max(x) < 16 && min(x) > -16) && (max(y) < 16 && min(y) > -16) && mean(abs(x(1:10))) < 1 && mean(abs(y(1:10))) < 1
					c = rand(1,3);
					p(1,1).select();
					p(1,1).hold('on')
					plot(x, y,'k-o','Color',c,'MarkerSize',5,'MarkerEdgeColor',[0 0 0], 'MarkerFaceColor',c);
					
					p(1,2).select();
					p(1,2).hold('on');
					t = 0:ifi:(ifi*length(x));
					t = t(1:length(x));
					plot(t,abs(x),'k-o','Color',c,'MarkerSize',5,'MarkerEdgeColor',[0 0 0], 'MarkerFaceColor',c);
					plot(t,abs(y),'k-o','Color',c,'MarkerSize',5,'MarkerEdgeColor',[0 0 0], 'MarkerFaceColor',c);
					maxv = max([maxv, max(abs(x)), max(abs(y))]);
					
					p(2,1).select();
					p(2,1).hold('on');
					plot(mean(x(1:10)), mean(y(1:10)),'ko','Color',c,'MarkerSize',5,'MarkerEdgeColor',[0 0 0], 'MarkerFaceColor',c);
					stdex = [stdex std(x(1:10))];
					stdey = [stdey std(y(1:10))];
					
					p(2,2).select();
					p(2,2).hold('on');
					plot3(mean(x(1:10)), mean(y(1:10)),a,'ko','Color',c,'MarkerSize',5,'MarkerEdgeColor',[0 0 0], 'MarkerFaceColor',c);
					
					if mean(x(14:16)) > 5 || mean(y(14:16)) > 5
						early(a) = 1;
					else
						early(a) = 0;
					end
					
					a = a + 1;
					
					%end
				end
			end
			
			p(1,1).select();
			grid on
			box on
			axis square; axis ij
			xlim([-10 10]); ylim([-10 10]);
			title('X vs. Y Eye Position in Degrees')
			xlabel('X Degrees')
			ylabel('Y Degrees')
			
			p(1,2).select();
			grid on
			box on
			if maxv > 10; maxv = 10; end
			axis([-0.01 0.4 0 maxv+0.1])
			title(sprintf('X and Y Position vs. time | Early = %g / %g', sum(early),length(early)))
			xlabel('Time (s)')
			ylabel('Degrees')
			
			p(2,1).select();
			grid on
			box on
			axis square; axis ij
			title(sprintf('Average X vs. Y Position for first 150ms STDX: %g | STDY: %g',mean(stdex),mean(stdey)))
			xlabel('X Degrees')
			ylabel('Y Degrees')
			
			p(2,2).select();
			grid on
			box on
			axis square; axis ij
			title('Average X vs. Y Position for first 150ms Over Time')
			xlabel('X Degrees')
			ylabel('Y Degrees')
			zlabel('Trial')
		end
		
	end
	
	%=======================================================================
	methods (Access = protected) %------------------PRIVATE METHODS
	%=======================================================================
	
		% ===================================================================
		%> @brief 
		%>
		%> @param
		%> @return
		% ===================================================================
		function closeUI(me, varargin)
			try delete(me.handles.parent); end %#ok<TRYNC>
			me.handles = struct();
			me.openUI = false;
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function makeUI(me, varargin)
			
		end
		
		% ===================================================================
		%> @brief 
		%>
		%> @param
		%> @return
		% ===================================================================
		function updateUI(me, varargin)
			
		end
		
		% ===================================================================
		%> @brief 
		%>
		%> @param
		%> @return
		% ===================================================================
		function notifyUI(me, varargin)
			
		end
		
		% ===================================================================
		%> @brief main parse loop for EDF events, has to be one big serial loop
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseEvents(me)
			isTrial = false;
			tri = 1; %current trial that is being parsed
			tri2 = 1; %trial ignoring incorrects
			eventN = 0;
			me.comment = me.raw.HEADER;
			me.trials = struct();
			me.correct.idx = [];
			me.correct.saccTimes = [];
			me.correct.fixations = [];
			me.breakFix = me.correct;
			me.incorrect = me.correct;
			me.trialList = [];
			
			me.ppd; %faster to cache this now (dependant property sets ppd_ too)
			
			sample = me.raw.FSAMPLE.gx(:,100); %check which eye
			if sample(1) == -32768 %only use right eye if left eye data is not present
				eyeUsed = 2; %right eye index for FSAMPLE.gx;
			else
				eyeUsed = 1; %left eye index
			end
			
			for i = 1:length(me.raw.FEVENT)
				isMessage = false;
				evt = me.raw.FEVENT(i);
				
				if evt.type == 24 %strcmpi(evt.codestring,'MESSAGEEVENT')
					isMessage = true;
					no = regexpi(evt.message,'^(?<NO>!cal|!mode|Validate|Reccfg|elclcfg|Gaze_coords|thresholds|elcl_)','names'); %ignore these first
					if ~isempty(no)  && ~isempty(no.NO)
						continue
					end
				end
				
				if isMessage && ~isTrial
					rt = regexpi(evt.message,'^(?<d>V_RT MESSAGE) (?<a>\w+) (?<b>\w+)','names');
					if ~isempty(rt) && ~isempty(rt.a) && ~isempty(rt.b)
						me.rtStartMessage = rt.a;
						me.rtEndMessage = rt.b;
						continue
					end
					
					xy = regexpi(evt.message,'^DISPLAY_COORDS \d? \d? (?<x>\d+) (?<y>\d+)','names');
					if ~isempty(xy)  && ~isempty(xy.x)
						me.display = [str2num(xy.x)+1 str2num(xy.y)+1];
						continue
					end
					
					id = regexpi(evt.message,'^(?<TAG>TRIALID)(\s*)(?<ID>\d*)','names');
					if ~isempty(id) && ~isempty(id.TAG)
						if isempty(id.ID) %we have a bug in early EDF files with an empty TRIALID!!!
							id.ID = '1010';
						end
						isTrial = true;
						eventN=1;
						me.trials(tri).variable = str2double(id.ID);
						me.trials(tri).idx = tri;
						me.trials(tri).correctedIndex = [];
						me.trials(tri).time = double(evt.time);
						me.trials(tri).sttime = double(evt.sttime);
						me.trials(tri).totaltime = (me.trials(tri).sttime - me.trials(1).sttime)/1e3;
						me.trials(tri).rt = false;
						me.trials(tri).rtstarttime = double(evt.sttime);
						me.trials(tri).fixations = [];
						me.trials(tri).saccades = [];
						me.trials(tri).nsacc = [];
						me.trials(tri).saccadeTimes = [];
						me.trials(tri).firstSaccade = NaN;
						me.trials(tri).rttime = [];
						me.trials(tri).uuid = [];
						me.trials(tri).correct = false;
						me.trials(tri).breakFix = false;
						me.trials(tri).incorrect = false;
						continue
					end
				end
				
				if isTrial
					
					if ~isMessage
						
						if strcmpi(evt.codestring,'STARTSAMPLES')
							me.trials(tri).startsampletime = double(evt.sttime);
							continue
						end
						
						if evt.type == 8 %strcmpi(evt.codestring,'ENDFIX')
							fixa = [];
							if isempty(me.trials(tri).fixations)
								fix = 1;
							else
								fix = length(me.trials(tri).fixations)+1;
							end
							if me.trials(tri).rt == true
								rel = me.trials(tri).rtstarttime;
								fixa.rt = true;
							else
								rel = me.trials(tri).sttime;
								fixa.rt = false;
							end
							fixa.n = eventN;
							fixa.ppd = me.ppd_;
							fixa.sttime = double(evt.sttime);
							fixa.entime = double(evt.entime);
							fixa.time = fixa.sttime - rel;
							fixa.length = fixa.entime - fixa.sttime;
							fixa.rel = rel;
							
							[fixa.gstx, fixa.gsty]  = toDegrees(me, [evt.gstx, evt.gsty]);
							[fixa.genx, fixa.geny]  = toDegrees(me, [evt.genx, evt.geny]);
							[fixa.x, fixa.y]		= toDegrees(me, [evt.gavx, evt.gavy]);
							[fixa.theta, fixa.rho]	= cart2pol(fixa.x, fixa.y);
							fixa.theta = rad2ang(fixa.theta);
							
							if fix == 1
								me.trials(tri).fixations = fixa;
							else
								me.trials(tri).fixations(fix) = fixa;
							end
							me.trials(tri).nfix = fix;
							eventN = eventN + 1;
							continue
						end
						
						if evt.type == 6 % strcmpi(evt.codestring,'ENDSACC')
							sacc = [];
							if isempty(me.trials(tri).saccades)
								nsacc = 1;
							else
								nsacc = length(me.trials(tri).saccades)+1;
							end
							if me.trials(tri).rt == true
								rel = me.trials(tri).rtstarttime;
								sacc.rt = true;
							else
								rel = me.trials(tri).sttime;
								sacc.rt = false;
							end
							sacc.n = eventN;
							sacc.ppd = me.ppd_;
							sacc.sttime = double(evt.sttime);
							sacc.entime = double(evt.entime);
							sacc.time = sacc.sttime - rel;
							sacc.length = sacc.entime - sacc.sttime;
							sacc.rel = rel;
							
							[sacc.gstx, sacc.gsty]	= toDegrees(me, [evt.gstx evt.gsty]);
							[sacc.genx, sacc.geny]	= toDegrees(me, [evt.genx evt.geny]);
							[sacc.x, sacc.y]		= deal((sacc.genx - sacc.gstx), (sacc.geny - sacc.gsty));
							[sacc.theta, sacc.rho]	= cart2pol(sacc.x, sacc.y);
							sacc.theta = rad2ang(sacc.theta);
							
							if sacc.rho > me.minSaccadeDistance; sacc.microSaccade = false;
							else sacc.microSaccade = true; end
							
							if nsacc == 1
								me.trials(tri).saccades = sacc;
							else
								me.trials(tri).saccades(nsacc) = sacc;
							end
							me.trials(tri).nsacc = nsacc;
							eventN = eventN + 1;
							continue
						end
						
						if evt.type == 16 %strcmpi(evt.codestring,'ENDSAMPLES')
							me.trials(tri).endsampletime = double(evt.sttime);
							idx = me.raw.FSAMPLE.time >= me.trials(tri).startsampletime & ...
								me.raw.FSAMPLE.time <= me.trials(tri).endsampletime;
							
							me.trials(tri).times = double(me.raw.FSAMPLE.time(idx));
							me.trials(tri).times = me.trials(tri).times - me.trials(tri).rtstarttime;
							
							me.trials(tri).gx = me.raw.FSAMPLE.gx(eyeUsed, idx);
							me.trials(tri).gx = me.trials(tri).gx - me.display(1)/2;
							
							me.trials(tri).gy = me.raw.FSAMPLE.gy(eyeUsed, idx);
							me.trials(tri).gy = me.trials(tri).gy - me.display(2)/2;
							
							me.trials(tri).hx = me.raw.FSAMPLE.hx(eyeUsed, idx);
							
							me.trials(tri).hy = me.raw.FSAMPLE.hy(eyeUsed, idx);
							
							me.trials(tri).pa = me.raw.FSAMPLE.pa(eyeUsed, idx);
							continue
						end
						
					else
						uuid = regexpi(evt.message,'^UUID (?<UUID>[\w]+)','names');
						if ~isempty(uuid) && ~isempty(uuid.UUID)
							me.trials(tri).uuid = uuid.UUID;
							continue
						end
						
						endfix = regexpi(evt.message,['^' me.rtStartMessage],'match');
						if ~isempty(endfix)
							me.trials(tri).rtstarttime = double(evt.sttime);
							me.trials(tri).rt = true;
							if ~isempty(me.trials(tri).fixations)
								for lf = 1 : length(me.trials(tri).fixations)
									me.trials(tri).fixations(lf).time = me.trials(tri).fixations(lf).sttime - me.trials(tri).rtstarttime;
									me.trials(tri).fixations(lf).rt = true;
								end
							end
							if ~isempty(me.trials(tri).saccades)
								for lf = 1 : length(me.trials(tri).saccades)
									me.trials(tri).saccades(lf).time = me.trials(tri).saccades(lf).sttime - me.trials(tri).rtstarttime;
									me.trials(tri).saccades(lf).rt = true;
									me.trials(tri).saccadeTimes(lf) = me.trials(tri).saccades(lf).time;
								end
							end
							continue
						end
						
						endrt = regexpi(evt.message,['^' me.rtEndMessage],'match');
						if ~isempty(endrt)
							me.trials(tri).rtendtime = double(evt.sttime);
							if isfield(me.trials,'rtstarttime')
								me.trials(tri).rttime = me.trials(tri).rtendtime - me.trials(tri).rtstarttime;
							end
							continue
						end
						
						id = regexpi(evt.message,'^TRIAL_RESULT (?<ID>(\-|\+|\d)+)','names');
						if ~isempty(id) && ~isempty(id.ID)
							me.trials(tri).entime = double(evt.sttime);
							me.trials(tri).result = str2num(id.ID);
							sT=[];
							me.trials(tri).saccadeTimes = [];
							for ii = 1:me.trials(tri).nsacc
								t = me.trials(tri).saccades(ii).time;
								me.trials(tri).saccadeTimes(ii) = t;
								if isnan(me.trials(tri).firstSaccade) && t > 0 && me.trials(tri).saccades(ii).microSaccade == false
									me.trials(tri).firstSaccade = t;
									sT=t;
								end
							end
							if me.trials(tri).result == 1
								me.trials(tri).correct = true;
								me.correct.idx = [me.correct.idx tri];
								me.trialList(tri) = me.trials(tri).variable;
								if ~isempty(sT) && sT > 0
									me.correct.saccTimes = [me.correct.saccTimes sT];
								else
									me.correct.saccTimes = [me.correct.saccTimes NaN];
								end
								me.trials(tri).correctedIndex = tri2;
								tri2 = tri2 + 1;
							elseif me.trials(tri).result == -1
								me.trials(tri).breakFix = true;
								me.breakFix.idx = [me.breakFix.idx tri];
								me.trialList(tri) = -me.trials(tri).variable;
								if ~isempty(sT) && sT > 0
									me.breakFix.saccTimes = [me.breakFix.saccTimes sT];
								else
									me.breakFix.saccTimes = [me.breakFix.saccTimes NaN];
								end
								me.trials(tri).correctedIndex = tri2;
								tri2 = tri2 + 1;
							elseif me.trials(tri).result == 0
								me.trials(tri).incorrect = true;
								me.incorrect.idx = [me.incorrect.idx tri];
								me.trialList(tri) = -me.trials(tri).variable;
								if ~isempty(sT) && sT > 0
									me.incorrect.saccTimes = [me.incorrect.saccTimes sT];
								else
									me.incorrect.saccTimes = [me.incorrect.saccTimes NaN];
								end
								me.trials(tri).correctedIndex = NaN;
							end
							me.trials(tri).deltaT = me.trials(tri).entime - me.trials(tri).sttime;
							isTrial = false;
							tri = tri + 1;
							continue
						end
					end
				end
			end
			
			%prune the end trial if invalid
			if ~me.trials(end).correct && ~me.trials(end).breakFix && ~me.trials(end).incorrect
				me.trials(end) = [];
				me.correct.idx = find([me.trials.correct] == true);
				me.correct.saccTimes = [me.trials(me.correct.idx).firstSaccade];
				me.breakFix.idx = find([me.trials.breakFix] == true);
				me.breakFix.saccTimes = [me.trials(me.breakFix.idx).firstSaccade];
				me.incorrect.idx = find([me.trials.incorrect] == true);
				me.incorrect.saccTimes = [me.trials(me.incorrect.idx).firstSaccade];
			end
			
			if max(abs(me.trialList)) == 1010 && min(abs(me.trialList)) == 1010
				me.needOverride = true;
				me.salutation('','---> TRIAL NAME BUG OVERRIDE NEEDED!\n',true);
			else
				me.needOverride = false;
			end
	end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseAsVars(me)
			me.vars = struct();
			me.vars(1).name = '';
			me.vars(1).variable = [];
			me.vars(1).idx = [];
			me.vars(1).correctedidx = [];
			me.vars(1).trial = [];
			me.vars(1).sTime = [];
			me.vars(1).sT = [];
			me.vars(1).uuid = {};
			for i = 1:length(me.trials)
				trial = me.trials(i);
				var = trial.variable;
				if trial.incorrect == true
					continue
				end
				if trial.variable == 1010
					continue
				end
				me.vars(var).name = num2str(var);
				me.vars(var).trial = [me.vars(var).trial; trial];
				me.vars(var).idx = [me.vars(var).idx i];
				me.vars(var).correctedidx = [me.vars(var).correctedidx i];
				me.vars(var).uuid = [me.vars(var).uuid, trial.uuid];
				me.vars(var).variable = [me.vars(var).variable var];
				if ~isempty(trial.saccadeTimes)
					me.vars(var).sTime = [me.vars(var).sTime trial.saccadeTimes(1)];
				else
					me.vars(var).sTime = [me.vars(var).sTime NaN];
				end
				me.vars(var).sT = [me.vars(var).sT trial.firstSaccade];
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseSecondaryEyePos(me)
			if me.isParsed && isstruct(me.tS)
				f=fieldnames(me.tS.eyePos); %get fieldnames
				re = regexp(f,'^CC','once'); %regexp over the cell
				idx = cellfun(@(c)~isempty(c),re); %check which regexp returned true
				f = f(idx); %use this index
				me.validation(1).uuids = f;
				me.validation.lengthCorrect = length(f);
				if length(me.correct.idx) == me.validation.lengthCorrect
					disp('Secondary Eye Position Data appears consistent with EDF parsed trials')
				else
					warning('Secondary Eye Position Data inconsistent with EDF parsed trials')
				end
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function parseFixationPositions(me)
			if me.isParsed
				for i = 1:length(me.trials)
					t = me.trials(i);
					f(1).isFix = false;
					f(1).idx = -1;
					f(1).times = -1;
					f(1).x = -1;
					f(1).y = -1;
					if isfield(t.fixations,'time')
						times = [t.fixations.time];
						fi = find(times > 50);
						if ~isempty(fi)
							f(1).isFix = true;
							f(1).idx = i;
							for jj = 1:length(fi)
								fx =  t.fixations(fi(jj));
								f(1).times(jj) = fx.time;
								f(1).x(jj) = fx.x;
								f(1).y(jj) = fx.y;
							end
						end
					end
					if t.correct == true
						bname='correct';
					elseif t.breakFix == true
						bname='breakFix';
					else
						bname='incorrect';
					end
					if isempty(me.(bname).fixations)
						me.(bname).fixations = f;
					else
						me.(bname).fixations(end+1) = f;
					end
				end
				
			end
			
		end
		
		% ===================================================================
		%> @brief
		%>
		% ===================================================================
		function [outx, outy] = toDegrees(me,in)
			if length(in)==2
				outx = (in(1) - me.xCenter) / me.ppd_;
				outy = (in(2) - me.yCenter) / me.ppd_;
			else
				outx = [];
				outy = [];
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		% ===================================================================
		function [outx, outy] = toPixels(me,in)
			if length(in)==2
				outx = (in(1) * me.ppd_) + me.xCenter;
				outy = (in(2) * me.ppd_) + me.yCenter;
			else
				outx = [];
				outy = [];
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		% ===================================================================
		function computeMicrosaccades(me)
			
			VFAC=me.VFAC;
			MINDUR=me.MINDUR;
			sampleRate = me.sampleRate;
			tic
			for jj = 1:length(me.trials)
				if me.trials(jj).incorrect == true;	continue;	end
				samples = []; sac = []; radius = []; monol=[]; monor=[];
				me.trials(jj).msacc = struct();
				me.trials(jj).sampleSaccades = [];
				me.trials(jj).microSaccades = [];
				samples(:,1) = me.trials(jj).times/1e3;
				samples(:,2) = me.trials(jj).gx/me.ppd;
				samples(:,3) = me.trials(jj).gy/me.ppd;
				samples(:,4) = nan(size(samples(:,1)));
				samples(:,5) = samples(:,4);
				eye_used = 0;
				try
					switch eye_used
						case 0
							v = vecvel(samples(:,2:3),sampleRate,2);
							[sac, radius] = microsacc(samples(:,2:3),v,VFAC,MINDUR);
						case 1
							v = vecvel(samples(:,2:3),sampleRate,2);
							[sac, radius] = microsacc(samples(:,4:5),v,VFAC,MINDUR);
						case 2
							MSlcoords=samples(:,2:3);
							MSrcoords=samples(:,4:5);
							vl = vecvel(MSlcoords,sampleRate,2);
							vr = vecvel(MSrcoords,sampleRate,2);
							[sacl, radiusl] = microsacc(MSlcoords,vl,VFAC,MINDUR);
							[sacr, radiusr] = microsacc(MSrcoords,vr,VFAC,MINDUR);
							[bsac, monol, monor] = binsacc(sacl,sacr);
							sac = saccpar(bsac);
					end
					me.trials(jj).radius = radius;
					for ii = 1:size(sac,1)
						me.trials(jj).msacc(ii).time = samples(sac(ii,1),1);
						me.trials(jj).msacc(ii).endtime = samples(sac(ii,2),1);
						me.trials(jj).msacc(ii).velocity = sac(ii,3);
						me.trials(jj).msacc(ii).dx = sac(ii,4);
						me.trials(jj).msacc(ii).dy = sac(ii,5);
						me.trials(jj).msacc(ii).dX = sac(ii,6);
						me.trials(jj).msacc(ii).dY = sac(ii,7);
						[theta,rho]=cart2pol(sac(ii,6),sac(ii,7));
						me.trials(jj).msacc(ii).theta = rad2ang(theta);
						me.trials(jj).msacc(ii).rho = rho;
						me.trials(jj).msacc(ii).isMicroSaccade = rho<=me.minSaccadeDistance;
					end
					if ~isempty(sac)
						me.trials(jj).sampleSaccades = [me.trials(jj).msacc(:).time];
						me.trials(jj).microSaccades = [me.trials(jj).sampleSaccades([me.trials(jj).msacc(:).isMicroSaccade])];
					else
						me.trials(jj).sampleSaccades = NaN;
						me.trials(jj).microSaccades = NaN;
					end
					if isempty(me.trials(jj).microSaccades); me.trials(jj).microSaccades = NaN; end
				catch ME
					getReport(ME)
				end
			end
			fprintf('<strong>�</strong> Parsing MicroSaccades took <strong>%g ms</strong>\n', round(toc*1000))
				
			function v = vecvel(xx,SAMPLING,TYPE)
				%------------------------------------------------------------
				%  FUNCTION vecvel.m
				%  Calculation of eye velocity from position data
				%
				%  INPUT:
				%   xy(1:N,1:2)     raw data, x- and y-components of the time series
				%   SAMPLING        sampling rate (number of samples per second)
				%   TYPE            velocity type: TYPE=2 recommended
				%
				%  OUTPUT:
				%   v(1:N,1:2)      velocity, x- and y-components
				%-------------------------------------------------------------
				
				N = length(xx);            % length of the time series
				v = zeros(N,2);
				
				switch TYPE
					case 1
						v(2:N-1,:) = [xx(3:end,:) - xx(1:end-2,:)]*SAMPLING/2;
					case 2
						v(3:N-2,:) = [xx(5:end,:) + xx(4:end-1,:) - xx(2:end-3,:) - xx(1:end-4,:)]*SAMPLING/6;
						v(2,:)     = [xx(3,:) - xx(1,:)]*SAMPLING/2;
						v(N-1,:)   = [xx(end,:) - xx(end-2,:)]*SAMPLING/2;
				end
				return
			end
			
			function [sac, radius] = microsacc(x,vel,VFAC,MINDUR)
				%-------------------------------------------------------------------
				%  FUNCTION microsacc.m
				%  Detection of monocular candidates for microsaccades;
				%
				%  INPUT:
				%   x(:,1:2)         position vector
				%   vel(:,1:2)       velocity vector
				%   VFAC             relative velocity threshold
				%   MINDUR           minimal saccade duration
				%
				%  OUTPUT:
				%   radius         threshold velocity (x,y) used to distinguish microsaccs
				%   sac(1:num,1)   onset of saccade
				%   sac(1:num,2)   end of saccade
				%   sac(1:num,3)   peak velocity of saccade (vpeak)
				%   sac(1:num,4)   horizontal component     (dx)
				%   sac(1:num,5)   vertical component       (dy)
				%   sac(1:num,6)   horizontal amplitude     (dX)
				%   sac(1:num,7)   vertical amplitude       (dY)
				%---------------------------------------------------------------------
				
				% SDS... VFAC (relative velocity threshold) E&M 2006 use a value of VFAC=5
				
				
				% compute threshold
				% SDS... this is sqrt[median(x^2) - (median x)^2]
				msdx = sqrt( median(vel(:,1).^2) - (median(vel(:,1)))^2 );
				msdy = sqrt( median(vel(:,2).^2) - (median(vel(:,2)))^2 );
				if msdx<realmin
					msdx = sqrt( mean(vel(:,1).^2) - (mean(vel(:,1)))^2 );
					if msdx<realmin
						error('msdx<realmin in microsacc.m');
					end
				end
				if msdy<realmin
					msdy = sqrt( mean(vel(:,2).^2) - (mean(vel(:,2)))^2 );
					if msdy<realmin
						error('msdy<realmin in microsacc.m');
					end
				end
				radiusx = VFAC*msdx;
				radiusy = VFAC*msdy;
				radius = [radiusx radiusy];
				
				% compute test criterion: ellipse equation
				test = (vel(:,1)/radiusx).^2 + (vel(:,2)/radiusy).^2;
				indx = find(test>1);
				
				% determine saccades
				% SDS..  this loop reads through the index of above-threshold velocities,
				%        storing the beginning and end of each period (i.e. each saccade)
				%        as the position in the overall time series of data submitted
				%        to the analysis
				N = length(indx);
				sac = [];
				nsac = 0;
				dur = 1;
				a = 1;
				k = 1;
				while k<N
					if indx(k+1)-indx(k)==1     % looks 1 instant ahead of current instant
						dur = dur + 1;
					else
						if dur>=MINDUR
							nsac = nsac + 1;
							b = k;             % hence b is the last instant of the consecutive series constituting a microsaccade
							sac(nsac,:) = [indx(a) indx(b)];
						end
						a = k+1;
						dur = 1;
					end
					k = k + 1;
				end
				
				% check for minimum duration
				% SDS.. this just deals with the final set of above threshold
				%       velocities; adds it to the list if the duration is long enough
				if dur>=MINDUR
					nsac = nsac + 1;
					b = k;
					sac(nsac,:) = [indx(a) indx(b)];
				end
				
				% compute peak velocity, horizonal and vertical components
				for s=1:nsac
					% onset and offset
					a = sac(s,1);
					b = sac(s,2);
					% saccade peak velocity (vpeak)
					vpeak = max( sqrt( vel(a:b,1).^2 + vel(a:b,2).^2 ) );
					sac(s,3) = vpeak;
					% saccade vector (dx,dy)            SDS..  this is the difference between initial and final positions
					dx = x(b,1)-x(a,1);
					dy = x(b,2)-x(a,2);
					sac(s,4) = dx;
					sac(s,5) = dy;
					
					% saccade amplitude (dX,dY)         SDS.. this is the difference between max and min positions over the excursion of the msac
					i = sac(s,1):sac(s,2);
					[minx, ix1] = min(x(i,1));              %       dX > 0 signifies rightward  (if ix2 > ix1)
					[maxx, ix2] = max(x(i,1));              %       dX < 0 signifies  leftward  (if ix2 < ix1)
					[miny, iy1] = min(x(i,2));              %       dY > 0 signifies    upward  (if iy2 > iy1)
					[maxy, iy2] = max(x(i,2));              %       dY < 0 signifies  downward  (if iy2 < iy1)
					dX = sign(ix2-ix1)*(maxx-minx);
					dY = sign(iy2-iy1)*(maxy-miny);
					sac(s,6:7) = [dX dY];
				end
				
			end
			
			function [sac, monol, monor] = binsacc(sacl,sacr)
				%-------------------------------------------------------------------
				%  FUNCTION binsacc.m
				%
				%  INPUT: saccade matrices from FUNCTION microsacc.m
				%   sacl(:,1:7)       microsaccades detected from left eye
				%   sacr(:,1:7)       microsaccades detected from right eye
				%
				%  OUTPUT:
				%   sac(:,1:14)       binocular microsaccades (right eye/left eye)
				%   monol(:,1:7)      monocular microsaccades of the left eye
				%   monor(:,1:7)      monocular microsaccades of the right eye
				%---------------------------------------------------------------------
				
				% SDS.. The aim of this routine is to pair up msaccs in L & R eyes that are
				%       coincident in time. Some msaccs in one eye may not have a matching
				%       msacc in the other; the code also seems to allow for a msacc in one
				%       eye matching 2 events in the other eye - in which case the
				%       larger amplitude one is selected, and the other discarded.
				
				if size(sacr,1)*size(sacl,1)>0
					
					% determine saccade clusters
					TR = max(sacr(:,2));
					TL = max(sacl(:,2));
					T = max([TL TR]);
					s = zeros(1,T+1);
					for i=1:size(sacl,1)
						s(sacl(i,1)+1:sacl(i,2)) = 1;   % SDS.. creates time-series with 1 for duration of left eye  msacc events and 0 for duration of intervals
						% NB.   sacl(i,1)+1    the +1 is necessary for the diff function [line 219] to correctly pick out the start instants of msaccs
					end
					for i=1:size(sacr,1)
						s(sacr(i,1)+1:sacr(i,2)) = 1;   % SDS.. superimposes similar for right eye; hence a time-series of binocular events
					end                                 %   ... 'binocular' means that either L, R or both eyes moved
					s(1) = 0;
					s(end) = 0;
					m = find(diff(s~=0));   % SDS.. finds time series positions of start and ends of (binocular) m.saccd phases
					N = length(m)/2;        % SDS.. N = number of microsaccades
					m = reshape(m,2,N)';    % SDS.. col 1 is all sacc onsets; col 2 is all sacc end points
					
					% determine binocular saccades
					NB = 0;
					NR = 0;
					NL = 0;
					sac = [];
					monol = [];
					monor = [];
					% SDS..  the loop counts through each position in the binoc list
					for i=1:N                                               % ..  'find' operates on the sacl (& sacr) matrices;
						l = find( m(i,1)<=sacl(:,1) & sacl(:,2)<=m(i,2) );  % ..   finds position of msacc in L eye list to match the timing of each msacc in binoc list (as represented by 'm')
						r = find( m(i,1)<=sacr(:,1) & sacr(:,2)<=m(i,2) );  % ..   finds position of msacc in R eye list ...
						% ..   N.B. some 'binoc' msaccs will not match one or other of the monoc lists
						if length(l)*length(r)>0                            % SDS..   Selects binoc msaccs.  [use of 'length' function is a bit quaint..  l and r should not be vectors, but single values..?]
							ampr = sqrt(sacr(r,6).^2+sacr(r,7).^2);         % ..      is allowing for 2 (or more) discrete monocular msaccs coinciding with a single event in the 'binoc' list
							ampl = sqrt(sacl(l,6).^2+sacl(l,7).^2);
							[h ir] = max(ampr);                             % hence r(ir) in L241 is the position in sacr of the larger amplitude saccade (if there are 2 or more that occurence of binoc saccade)
							[h il] = max(ampl);                             % hence l(il) in L241 is the position in sacl of the larger amplitude saccade (if there are 2 or more that occurence of binoc saccade)
							NB = NB + 1;
							sac(NB,:) = [sacr(r(ir),:) sacl(l(il),:)];      % ..      the final compilation selects the larger amplitude msacc to represent the msacc in that eye
						else
							% determine monocular saccades
							if isempty(l)                                 % If no msacc in L eye
								NR = NR + 1;
								monor(NR,:) = sacr(r,:);                    %..  record R eye monoc msacc.
							end
							if isempty(r)                                 %If no msacc in R eye
								NL = NL + 1;
								monol(NL,:) = sacl(l,:);                    %..  record L eye monoc msacc
							end
						end
					end
				else
					% special cases of exclusively monocular saccades
					if size(sacr,1)==0
						sac = [];
						monor = [];
						monol = sacl;
					end
					if size(sacl,1)==0
						sac = [];
						monol = [];
						monor = sacr;
					end
				end
			end
			
			function sac = saccpar(bsac)
				%-------------------------------------------------------------------
				%  FUNCTION saccpar.m
				%  Calculation of binocular saccade parameters;
				%
				%  INPUT: binocular saccade matrix from FUNCTION binsacc.m
				%   sac(:,1:14)       binocular microsaccades
				%
				%  OUTPUT:
				%   sac(:,1:9)        parameters averaged over left and right eye data
				%---------------------------------------------------------------------
				if size(bsac,1)>0
					sacr = bsac(:,1:7);
					sacl = bsac(:,8:14);
					
					% 1. Onset
					a = min([sacr(:,1)'; sacl(:,1)'])';     % produces single column vector of ealier onset in L v R eye msaccs
					
					% 2. Offset
					b = max([sacr(:,2)'; sacl(:,2)'])';     % produces single column vector of later offset in L v R eye msaccs
					
					% 3. Duration
					DR = sacr(:,2)-sacr(:,1)+1;
					DL = sacl(:,2)-sacl(:,1)+1;
					D = (DR+DL)/2;
					
					% 4. Delay between eyes
					delay = sacr(:,1) - sacl(:,1);
					
					% 5. Peak velocity
					vpeak = (sacr(:,3)+sacl(:,3))/2;
					
					% 6. Saccade distance
					dist = (sqrt(sacr(:,4).^2+sacr(:,5).^2)+sqrt(sacl(:,4).^2+sacl(:,5).^2))/2;
					angle1 = atan2((sacr(:,5)+sacl(:,5))/2,(sacr(:,4)+sacl(:,4))/2);
					
					% 7. Saccade amplitude
					ampl = (sqrt(sacr(:,6).^2+sacr(:,7).^2)+sqrt(sacl(:,6).^2+sacl(:,7).^2))/2;
					angle2 = atan2((sacr(:,7)+sacl(:,7))/2,(sacr(:,6)+sacl(:,6))/2);        %SDS..  NB 'atan2'function operates on (y,x) - not (x,y)!
					
					sac = [a b D delay vpeak dist angle1 ampl angle2];
				else
					sac = [];
				end
			end
			
		end
		
	end
	
end

