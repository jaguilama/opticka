% ========================================================================
%> @brief barStimulus single bar stimulus, inherits from baseStimulus
% ========================================================================
classdef barStimulus < baseStimulus

   properties %--------------------PUBLIC PROPERTIES----------%
		type = 'solid'
		%> scale up the texture in the bar
		pixelScale = 1 
		%> width of bar
		barWidth = 1
		%> length of bar
		barLength = 4
		%> contrast multiplier
		contrast = 1
		%> texture scale
		scale = 1
		%> texture interpolation
		interpMethod = 'nearest'
		%>
		textureAspect = 1
	end
	
	properties (SetAccess = protected, GetAccess = public)
		family = 'bar'
		%> computed matrix for the bar
		matrix
		%> random matrix used for texture generation
		rmatrix
	end
	
	properties (SetAccess = private, GetAccess = public, Hidden = true)
		typeList = {'solid','random','randomColour','randomN','randomBW'}
		interpMethodList = {'nearest','linear','spline','cubic'}
	end
	
	properties (SetAccess = private, GetAccess = private)
		allowedProperties='type|pixelScale|barWidth|barLength|angle|speed|contrast|scale|interpMethod';
		ignoreProperties = 'interpMethod|matrix|rmatrix|pixelScale';
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
		%> @return instance of opticka class.
		% ===================================================================
		function obj = barStimulus(varargin) 
			%Initialise for superclass, stops a noargs error
			if nargin == 0
				varargin.family = 'bar';
				varargin.colour = [1 1 1];
				varargin.speed = 2;
				varargin.startPosition = -2;
			end
			
			obj=obj@baseStimulus(varargin); %we call the superclass constructor first
			
			if nargin>0
				obj.parseArgs(varargin, obj.allowedProperties);
			end
			
			obj.ignoreProperties = ['^(' obj.ignorePropertiesBase '|' obj.ignoreProperties ')$'];
			obj.salutation('constructor','Bar Stimulus initialisation complete');
		end
		
		% ===================================================================
		%> @brief Generate an structure for runExperiment
		%>
		%> @param sM screenManager object for reference
		%> @return stimulus structure.
		% ===================================================================
		function setup(obj,sM)
			
			reset(obj);
			obj.inSetup = true;
			
			obj.sM = sM;
			obj.ppd=sM.ppd;
			obj.ifi=sM.screenVals.ifi;
			obj.screenWidth = sM.screenVals.width;
			obj.screenHeight = sM.screenVals.height;
			if isempty(obj.xCenter);obj.xCenter=sM.xCenter;end
			if isempty(obj.yCenter);obj.yCenter=sM.yCenter;end
			if isempty(obj.win);obj.win = sM.win;end
			
			fn = fieldnames(barStimulus);
			for j=1:length(fn)
				if isempty(obj.findprop([fn{j} 'Out'])) && isempty(regexp(fn{j},obj.ignoreProperties, 'once'))%create a temporary dynamic property
					p=obj.addprop([fn{j} 'Out']);
					p.Transient = true;%p.Hidden = true;
					if strcmp(fn{j},'xPosition');p.SetMethod = @set_xPositionOut;end
					if strcmp(fn{j},'yPosition');p.SetMethod = @set_yPositionOut;end
				end
				if isempty(regexp(fn{j},obj.ignoreProperties, 'once'))
					obj.([fn{j} 'Out']) = obj.(fn{j}); %copy our property value to our tempory copy
				end
			end
			
			if isempty(obj.findprop('doDots'));p=obj.addprop('doDots');p.Transient = true;end
			if isempty(obj.findprop('doMotion'));p=obj.addprop('doMotion');p.Transient = true;end
			if isempty(obj.findprop('doDrift'));p=obj.addprop('doDrift');p.Transient = true;end
			if isempty(obj.findprop('doFlash'));p=obj.addprop('doFlash');p.Transient = true;end
			obj.doDots = false;
			obj.doMotion = false;
			obj.doDrift = false;
			obj.doFlash = false;
			
			obj.constructMatrix(obj.ppd) %make our matrix
			obj.texture=Screen('MakeTexture',obj.win,obj.matrix,1,[],2);
			if obj.speed>0 %we need to say this needs animating
				obj.doMotion=true;
			else
				obj.doMotion=false;
			end
			
			obj.inSetup = false;
			obj.setRect();
			
		end
		
		% ===================================================================
		%> @brief Update an structure for runExperiment
		%>
		%> @param in runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function update(obj)
			resetTicks(obj);
			obj.xCenter=obj.sM.xCenter;
			obj.yCenter=obj.sM.yCenter;
			obj.constructMatrix(obj.ppd) %make our matrix
			obj.texture=Screen('MakeTexture',obj.win,obj.matrix,1,[],2);
			obj.setRect();
		end
		
		% ===================================================================
		%> @brief Draw an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function draw(obj)
			if obj.isVisible && (obj.tick > obj.delayTicks)
				Screen('DrawTexture',obj.win,obj.texture,[],obj.mvRect,obj.angleOut);
			end
			obj.tick = obj.tick + 1;
		end
		
		% ===================================================================
		%> @brief Animate an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function animate(obj)
			if obj.mouseOverride
				getMousePosition(obj);
				if obj.mouseValid
					obj.mvRect = CenterRectOnPointd(obj.mvRect, obj.mouseX, obj.mouseY);
				end
			else
			end
			if obj.doMotion == 1
				obj.mvRect=OffsetRect(obj.mvRect,obj.dX_,obj.dY_);
			end
		end
		
		% ===================================================================
		%> @brief Reset an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return
		% ===================================================================
		function reset(obj)
			obj.texture=[];
			obj.mvRect = [];
			obj.dstRect = [];
			obj.removeTmpProperties;
			obj.win = [];
			obj.xCenter = [];
			obj.yCenter = [];
			resetTicks(obj);
		end
		
		% ===================================================================
		%> @brief constructMatrix makes the texture matrix to fill the bar with
		%>
		%> @param ppd use the passed pixels per degree to make a RGBA matrix of
		%> the correct dimensions
		% ===================================================================
		function constructMatrix(obj,ppd)
			if ~exist('ppd','var');ppd=obj.ppd;end
			obj.matrix=[]; %reset the matrix
			
			try
				if isempty(obj.findprop('barWidthOut'));
					bwpixels = round(obj.barWidth*ppd);
				else
					bwpixels = round(obj.barWidthOut*ppd);
				end
				if isempty(obj.findprop('barLengthOut'));
					blpixels = round(obj.barLength*ppd);
				else
					blpixels = round(obj.barLengthOut*ppd);
				end
				if rem(bwpixels,2);bwpixels=bwpixels+1;end
				if rem(blpixels,2);blpixels=blpixels+1;end
				bwscale = round(bwpixels/obj.scale)+1;
				blscale = round(blpixels/obj.scale)+1;

				tmat = ones(blscale,bwscale,4); %allocate the size correctly
				rmat=ones(blscale,bwscale);
				switch obj.type
					case 'random'
						rmat=rand(blscale,bwscale);
						for i=1:3
							tmat(:,:,i)=tmat(:,:,i).*rmat;
						end
						tmat(:,:,4)=ones(blscale,bwscale)*obj.alpha;
					case 'randomColour'
						for i=1:3
							rmat=rand(blscale,bwscale);
							tmat(:,:,i)=tmat(:,:,i).*rmat;
						end
						tmat(:,:,4)=ones(blscale,bwscale)*obj.alpha;
					case 'randomN'
						rmat=randn(blscale,bwscale);
						for i=1:3
							tmat(:,:,i)=tmat(:,:,i).*rmat;
						end
						tmat(:,:,4)=ones(blscale,bwscale)*obj.alpha;
					case 'randomBW'
						rmat=rand(blscale,bwscale);
						rmat(rmat < 0.5) = 0;
						rmat(rmat >= 0.5) = 1;
						for i=1:3
							tmat(:,:,i)=tmat(:,:,i).*rmat;
						end
						tmat(:,:,4)=ones(blscale,bwscale)*obj.alpha;
					otherwise
						tmat(:,:,1)=ones(blscale,bwscale) * (obj.colour(1) * obj.contrastOut);
						tmat(:,:,2)=ones(blscale,bwscale) * (obj.colour(2) * obj.contrastOut);
						tmat(:,:,3)=ones(blscale,bwscale) * (obj.colour(3) * obj.contrastOut);
						tmat(:,:,4)=ones(blscale,bwscale)*obj.alpha;
				end
				aw=0:obj.scale:bwpixels;
				al=0:obj.scale:blpixels;
				[a,b]=meshgrid(aw,al);
				[A,B]=meshgrid(0:bwpixels,0:blpixels);
				for i=1:4
					outmat(:,:,i) = interp2(a,b,tmat(:,:,i),A,B,obj.interpMethod);
				end
				obj.matrix = outmat(1:blpixels,1:bwpixels,:);
				obj.rmatrix = rmat;
			catch %#ok<CTCH>
				if isempty(obj.findprop('barWidthOut'));
					bwpixels = round(obj.barWidth*ppd);
				else
					bwpixels = round(obj.barWidthOut*ppd);
				end
				if isempty(obj.findprop('barLengthOut'));
					blpixels = round(obj.barLength*ppd);
				else
					blpixels = round(obj.barLengthOut*ppd);
				end
				tmat = ones(blpixels,bwpixels,4); %allocate the size correctly
				tmat(:,:,1)=ones(blpixels,bwpixels)*obj.colour(1);
				tmat(:,:,2)=ones(blpixels,bwpixels)*obj.colour(2);
				tmat(:,:,3)=ones(blpixels,bwpixels)*obj.colour(3);
				tmat(:,:,4)=ones(blpixels,bwpixels)*obj.colour(4);
				rmat=ones(blpixels,bwpixels);
				obj.matrix=tmat;
				obj.rmatrix=rmat;
			end
		end
		
		
		% ===================================================================
		%> @brief barLength set method
		%>
		%> @param length of bar
		%> @return
		% ===================================================================
		function set.barLength(obj,value)
			if ~(value > 0)
				value = 0.2;
			end
			obj.barLength = value;
		end
		
		% ===================================================================
		%> @brief barWidth set method
		%>
		%> @param width of bar in degrees
		%> @return
		% ===================================================================
		function set.barWidth(obj,value)
			if ~(value > 0)
				value = 0.1;
			end
			obj.barWidth = value;
		end
		
	end %---END PUBLIC METHODS---%
	
	%=======================================================================
	methods ( Access = private ) %-------PRIVATE METHODS-----%
	%=======================================================================
		% ===================================================================
		%> @brief xPositionOut Set method
		%>
		% ===================================================================
		function set_xPositionOut(obj,value)
			obj.xPositionOut = value*obj.ppd;
			if ~obj.inSetup; obj.setRect; end
		end
		
		% ===================================================================
		%> @brief yPositionOut Set method
		%>
		% ===================================================================
		function set_yPositionOut(obj,value)
			obj.yPositionOut = value*obj.ppd;
			if ~obj.inSetup; obj.setRect; end
		end
	end
end