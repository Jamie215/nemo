% A surrogate model of a neural population, used when simulating in 
% ModeConfurable.POPULATION_MODE. 
% 
% This is intended as a default implementation. To make a different one, 
% subclass this class and make the following changes: 
%  1) To use a different model of static (bias) errors, override the methods 
%     createBiasModel(...) and getBias(...)
%  2) To use a different model of fluctuating noise, override getNoise(...)
%     and createNoiseModel(...) 
%  3) Change the static method getModel(...) to return instances of your 
%     subclass
classdef PopulationModeModel < handle

    properties (SetAccess = private)
        pop = [];
        
        originIndices = []; % see makeOriginIndices() 
        
        dt = .001;
        
        % bias grid ... 
        X = [];
        Y = [];
        Z = [];
        R = [];
        biasValues = []; % length(originIndices) x (bias grid) 
        
        noiseOriginInd = [];
        noiseCorr = [];
        
        % discrete state-space filter to generate noise with realistic
        % power spectrum
        nfX = []; %state of noise filters
        nfU = []; %need input from previous time step for state update
        nfA = []; %dynamics matrix for model of noise frequency dependence
        nfB = []; %input matrix
        nfC = []; %output matrix
        nfD = []; %passthrough matrix
        
        noiseTime = [];
        noiseSamples = [];
    end
    
    methods (Access = public)
        
        function pmm = PopulationModeModel(pop) 
            pmm.pop = pop;
            pmm.originIndices = makeOriginIndices(pmm.pop);
            createBiasModel(pmm, pmm.originIndices);
            createNoiseModel(pmm, pmm.originIndices);
        end
        
        % Models bias (a function of population state) in the population's 
        % DecodedOutputs. This is called via initialize() prior to run(...). 
        function createBiasModel(pmm, originIndices)
            p = pmm.pop;
            
            a = 3; % bias is modelled over a*[-radius radius] 
            
            % for dimensions 1-3 we sample on a line/square/cube; for 
            % higher dimensions we sample on a line and assume radial
            % symmetry 
            if length(p.radii) == 1
                np = 301;
                pmm.X = makeVector(a*p.radii(1), np);
                pmm.biasValues = getBiasSamples(pmm, pmm.X);
            elseif length(p.radii) == 2
                np = 101;
                pmm.X = makeVector(a*p.radii(1), np);
                pmm.Y = makeVector(a*p.radii(2), np);                
                [x, y] = meshgrid(pmm.X, pmm.Y); 
                
                % note: the transpose below makes the biasValues line up
                % with pmm.X and pmm.Y
                bv = getBiasSamples(pmm, [reshape(x', 1, np^2); reshape(y', 1, np^2)]);
                pmm.biasValues = reshape(bv, [length(originIndices) np np]);
            elseif length(p.radii) == 3
                np = 41;
                pmm.X = makeVector(a*p.radii(1), np);
                pmm.Y = makeVector(a*p.radii(2), np);
                pmm.Z = makeVector(a*p.radii(3), np);

                [x, y, z] = meshgrid(pmm.X, pmm.Y, pmm.Z);
                x = permute(x, [2, 1, 3]); 
                y = permute(y, [2, 1, 3]);
                z = permute(z, [2, 1, 3]);
                
                bv = getBiasSamples(pmm, [reshape(x, 1, np^3); reshape(y, 1, np^3); reshape(z, 1, np^3)]);
                pmm.biasValues = reshape(bv, [length(originIndices) np np np]);
            else % for higher dimensions we sample along one dimension ...
                radius = a*p.radii(1); %TODO: handle unequal radii
                pmm.R = 0:(radius/(201-1)):radius;
                pmm.biasValues = getBiasSamples(pmm, [pmm.R; zeros(length(p.radii)-1, length(pmm.R))]);
            end
        end
        
        % Models time-varying noise in the population's DecodedOutputs. 
        % This is called via initialize() prior to run(...). 
        function createNoiseModel(pmm, originIndices)
            nd = length(originIndices); %total # dimensions across origins
            
            dt = pmm.dt;
            T = 1;
            time = dt:dt:T;
            
            n = 10;             
            points = Population.genRandomPoints(n, pmm.pop.radii, 0);
            freq = 2*pi*(0:1/T:(1/dt/2-1/T));
            
            rho = zeros(nd, nd); %correlations
            mags = zeros(nd, length(freq)); % fourier magnitudes 
            scaleForAverage = 1/n;
            for i = 1:n
                fprintf('.')
                noiseMatrix = getNoiseSamples(pmm, points(:,i), dt, T);
                
                rho = rho + scaleForAverage*corr(noiseMatrix');
                
                for j = 1:nd
                    f = fft(noiseMatrix(j,:)) / length(time) * 2 / pi^.5;
                    mags(j,:) = mags(j,:) + scaleForAverage*abs(f(1:length(freq)));  
                end
            end    
            pmm.noiseCorr = rho;
            fprintf('\n')
            
            % here we set up a linear system to filter random noise in order 
            % to produce noise with a realistic spectrum (note we will 
            % expect random noise with unit variance at each frequency) 
            pmm.nfU = zeros(nd, 1);
            pmm.nfX = zeros(2*nd, 1);
            pmm.nfA = zeros(2*nd, 2*nd);
            pmm.nfB = zeros(2*nd, nd);
            pmm.nfC = zeros(nd, 2*nd);
            pmm.nfD = zeros(nd, nd);
            
            % find filter parameters for each output
            for i = 1:nd
                sys = fitTF(freq, mags(i,:));
                sysd = c2d(sys, dt);
                
                [A, B, C, D] = tf2ss(sysd.num{:}, sysd.den{:}); 
                ii = 2*(i-1)+[1 2];
                pmm.nfA(ii, ii) = A;
                pmm.nfB(ii, i) = B;
                pmm.nfC(i, ii) = C;
                pmm.nfD(i, i) = D;
            end   
            
            %note: temporal filtering shouldn't affect correlations
            % except transiently when starting from zero
        end
        
        % indices: list of indices of origins to which each value returned
        %   from getError(...) belongs. For example if there are two 
        %   origins, the first 2D and the second 3D, indices=[1,1,2,2,2].
        function indices = getOriginIndices(pmm)
            indices = pmm.originIndices;
        end
        
        % state: population state vector  
        % bias: vector of bias values (a static function of the state that
        %   is encoded by the population) 
        function bias = getBias(pmm, state) 
            bias = zeros(size(pmm.originIndices));
            
            if length(state) == 1 
                xInd = getIndex(pmm.X, state);
                bias = pmm.biasValues(:,xInd);
            elseif length(state) == 2
                xInd = getIndex(pmm.X, state(1));
                yInd = getIndex(pmm.Y, state(2));
                bias = pmm.biasValues(:,xInd,yInd);
            elseif length(state) == 3
                xInd = getIndex(pmm.X, state(1));
                yInd = getIndex(pmm.Y, state(2));
                zInd = getIndex(pmm.Z, state(3));
                bias = pmm.biasValues(:,xInd,yInd,zInd);
            else 
                rInd = getIndex(pmm.R, norm(state));
                bias = pmm.biasValues(:,rInd);
            end
        end
        
        % time: end of simulation time step
        % noise: vector of noise values (a random variable with spatial and
        %   temporal correlations)
        function noise = getNoise(pmm, time) 
            noiseInd = [];
            if ~isempty(pmm.noiseTime)
                noiseInd = round((time - pmm.noiseTime(1)) / pmm.dt);
                if noiseInd < 1 || noiseInd > length(pmm.noiseTime)
                    noiseInd = [];
                end
            end
            if isempty(noiseInd) 
                nSteps = 1000;
                pmm.noiseTime = time:pmm.dt:(time+(nSteps-1)*pmm.dt);
                pmm.noiseSamples = generateNoise(pmm, nSteps);
                noiseInd = 1;
            end 
            noise = pmm.noiseSamples(:,noiseInd);
        end
        
        % nSteps: number of noise samples to generate (each sample is a
        %   vector where each element corresponds to a certain dimension of
        %   a certain Origin)
        % noise: correlated, filtered noise samples (total output dims x nSteps)
        function noise = generateNoise(pmm, nSteps)
            scale = (1/pmm.dt)^.5; % to meet our linear system's expectation of input with unit variance at each frequency
            unfiltered = [pmm.nfU scale * PoissonSpikeGenerator.randncov(nSteps, pmm.noiseCorr)];
                        
            x = pmm.nfX;
            A = pmm.nfA; B = pmm.nfB; C = pmm.nfC; D = pmm.nfD;
            
            %TODO: this filtering is about 10% of error model runtime and
            %could be almost eliminated by using Matlab's filter function
            noise = zeros(size(unfiltered,1), nSteps);
            for i = 1:nSteps
                x = A*x + B*unfiltered(:,i);
                noise(:,i) = C*x + D*unfiltered(:,i+1);
            end
            
            pmm.nfU = unfiltered(:,end);
            pmm.nfX = x;
        end
        
        % Obtains samples of bias (distortion) error for DecodedOrigins 
        % which can then be fit to a model. 
        % 
        % originInd: a vector the same length as the sum of dimensions of 
        %   all origins, that specifies the origin to which each bias 
        %   element belongs. Each element is the index of an origin. For 
        %   example if there are two origins, the first 2D and the second 
        %   3D, indices=[1,1,2,2,2].
        % evalPoints: population states at which bias is sampled (dim x #points)
        % bias: array of bias errors at each eval point for each
        %   origin (length(originInd) x size(evalPoints,2))
        % ideal: ideal values (actual = ideal + bias)
        function [bias, ideal] = getBiasSamples(pmm, evalPoints)
            rates = getRates(pmm.pop, evalPoints, 0, 0);

            bias = zeros(length(pmm.originIndices), size(evalPoints, 2));
            ideal = zeros(size(bias));
            for i = 1:length(pmm.pop.origins)
                origin = pmm.pop.origins{i}; 
                ind = find(pmm.originIndices == i);
                ideal(ind,:) = origin.f(evalPoints);
                actual = origin.decoders * rates;  
                bias(ind,:) = actual - ideal(ind,:);
            end
        end
        
        % A convenience method for subclasses. Obtains samples of
        % time-varying noise in DecodedOrigin outputs at a single value of
        % the population state (evaluation point). 
        % 
        % originInd: a vector the same length as the sum of dimensions of 
        %   all origins, that specifies the origin to which each bias 
        %   element belongs. Each element is the index of an origin. For 
        %   example if there are two origins, the first 2D and the second 
        %   3D, indices=[1,1,2,2,2].
        % evalPoint: population state at which the noise is to be sampled
        %   for some period of time
        % dt: time step of simulation for collecting samples (s)
        % T: duration of simulaton period (s)
        % noise: cell array of noise samples per origin
        function noise = getNoiseSamples(pmm, evalPoint, dt, T)
            p = pmm.pop;
            
            if isempty(evalPoint)
                evalPoint = zeros(size(p.radii));
            end

            time = dt:dt:T;
            noise = zeros(length(pmm.originIndices), length(time));
            
            drive = getDrive(p, evalPoint);
            reset(p);
            for i = 1:length(time)
                activity = run(p.spikeGenerator, drive, time(i)-dt, time(i), 1); 
                for j = 1:length(p.origins)
                    setActivity(p.origins{j}, time(i), activity);
                    noise(pmm.originIndices == j,i) = getOutput(p.origins{j});
                end
            end

            [bias, ideal] = getBiasSamples(pmm, evalPoint);  
            noise = noise - repmat(ideal + bias, 1, length(time));
        end
        
    end
    
    methods (Static) 
        
        % pop: the neural population for which to create a surrogate model
        % model: the surrogate model
        % 
        % Note: Populations call this method to obtain surrogate models of
        % themselves, so change it if you want them to use a subclass. 
        function model = getModel(pop)
            model = PopulationModeModel(pop);
        end
    end
    
end

% for bias lookup tables
function result = getIndex(X, x)
    result = max(1, min(length(X), 1+round((x - X(1)) / (X(2)-X(1)))));
end

% Creates a vector for use in meshgrid; radius is extent from zero in each
% direction, nPoints is # points total
function result = makeVector(radius, nPoints)
    result = -radius:(2*radius/(nPoints-1)):radius;
end

% This class generates a list of noise values at each time step, each of
% which belongs to a certain origin. The return value is a list of
% origin numbers to which each noise value belongs. For example if there
% are two origins, the first 2D and the second 3D, result=[1,1,2,2,2]. 
function result = makeOriginIndices(pop)
    nTotalDim = 0;
    for i = 1:length(pop.origins)
        nTotalDim = nTotalDim + pop.origins{i}.dim;
    end

    result = zeros(1,nTotalDim);
    c = 0;
    for i = 1:length(pop.origins)
        result(c+(1:pop.origins{i}.dim)) = i;
        c = c + pop.origins{i}.dim;
    end
end

% freq: list of frequencies 
% mags: fourier magnitudes at given frequencies
% sys: continuous-time transfer function that approximates mags
%   given white-noise input
function sys = fitTF(freq, mags)
    % there is typically a noisy resonant peak ... 
    smoothed = conv(mags, ones(1,10)/10, 'same');            
    maxFreq = .75*freq(find(smoothed == max(smoothed), 1, 'first'));
    maxFreq = max(2*pi*50, min(2*pi*300, maxFreq)); 

    % guess at the scales of transfer function parameters?[a0 a1 a2 w0 1/Q] for H(s) = (a2*s^2 + a1*s + a0) / (s^2 + w0/Q*s + w0^2) 
    a0 = mean(mags(2:5));
    a2 = mean(mags(end-3:end));
    a1 = (a0 + a2) / 2;
    w0 = maxFreq;
    Q = 2;
    s = [a2 a1 a0 w0 Q]; 

    % note that errfun params x(i) are expected to be close to 1 
    errfun = @(x) tfError(freq, mags, x(1)*s(1), x(2)*s(2), x(3)*s(3), x(4)*s(4), x(5)*s(5));
    options = optimset('TolX', 1e-10, 'TolFun', 1e-10, 'Algorithm','levenberg-marquardt');
    
    % solver often quits right away if we start with a decent estimate, so 
    % we check this and try a different starting point as needed
    OK = 0;
    while ~OK
        p = max(0.1, 1 + .25*randn(1,5)); %initial conditions of parameters
        [p, RESNORM, RESIDUAL, EXITFLAG, OUTPUT] = lsqnonlin(errfun, p, [], [], options);
        if ~ismember(EXITFLAG, [2, 3, 4]) && p(4) > 1e-3 && p(5) > 1e-3
            OK = 1;
        end
    end
    
    p = p .* s;
    sys = tf([p(1) p(2)*p(4)/p(5) p(3)*p(4)^2], [1 p(4)/p(5) p(4)^2]);

    [sysMag, sysPhase] = bode(sys, freq); plot(freq, mags, 'k'), hold on, plot(freq, squeeze(sysMag), 'b') 
end


% Calculates error in a fit of magnitude vs frequency to a 2nd-order
% transfer function.
% 
% The transfer function is: 
%   H(s) = (kss*s^2 + ks*(w0/Q)*s + k) / (s^2 + (w0/Q)*s + w0^2)
% 
% freq: frequencies (radians/s)
% mag: Fourier magnitudes at above frequencies
% result: mean-squared error between mag and the transfer function magnitude 
function result = tfError(freq, mag, kss, ks, k, w0, Q)
    sys = tf([kss ks*w0/Q k*w0^2], [1 w0/Q w0^2]);
    [sysMag, sysPhase] = bode(sys, freq);
    result = mean( (mag' - squeeze(sysMag)).^2 );
    
    if nargout == 0
        plot(freq, mag, 'k', freq, squeeze(sysMag), 'r')
    end
end