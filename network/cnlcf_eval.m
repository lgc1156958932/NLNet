function res = cnlcf_eval(net, x, dzdy, res, varargin)
%CNLCF_EVAL  Evaluate the network.
%
%   RES = NET_EVAL(NET, X) evaluates the convnet NET on data X.
%   RES = NET_EVAL(NET, X, DZDY) evaluates the convnent NET and its
%   derivative on data X and output derivative DZDY.
%   RES = NET_EVAL(NET, X, [], RES) evaluates the NET on X reusing the
%   structure RES.
%   RES = NET_EVAL(NET, X, DZDY, RES) evaluates the NET on X and its
%   derivatives reusing the structure RES.
%
%   The format of the network structure NET and of the result
%   structure RES are described in some detail below. Most networks
%   expect the input data X to be standardized, for example by
%   rescaling the input image(s) and subtracting a mean. Doing so is
%   left to the user, but information on how to do this is usually
%   contained in the `net.meta` field of the NET structure (see
%   below).
%
%   Networks can run either on the CPU or GPU. Use NET_MOVE()
%   to move the network parameters between these devices.
%
%   NET_EVAL(NET, X, DZDY, RES, 'OPT', VAL, ...) takes the following
%   options:
%
%   `Mode`:: `normal`
%      Specifies the mode of operation. It can be either `'normal'` or
%      `'test'`. In test mode, dropout and batch-normalization are
%      bypassed. Note that, when a network is deployed, it may be
%      preferable to *remove* such blocks altogether.
%
%   `ConserveMemory`:: `false`
%      Aggressively delete intermediate results. This in practice has
%      a very small performance hit and allows training much larger
%      models. However, it can be useful to disable it for
%      debugging. Keeps the values in `res(1)` (input) and `res(end)`
%      (output) with the outputs of `loss` and `softmaxloss` layers.
%      It is also possible to preserve individual layer outputs
%      by setting `net.layers{...}.precious` to `true`.
%      For back-propagation, keeps only the derivatives with respect to
%      weights.
%
%   `CuDNN`:: `true`
%      Use CuDNN when available.
%
%   `Accumulate`:: `false`
%      Accumulate gradients in back-propagation instead of rewriting
%      them. This is useful to break the computation in sub-batches.
%      The gradients are accumulated to the provided RES structure
%      (i.e. to call VL_SIMPLENN(NET, X, DZDY, RES, ...).
%
%   `SkipForward`:: `false`
%      Reuse the output values from the provided RES structure and compute
%      only the derivatives (backward pass).
%

%   ## The result format
%
%   NET_EVAL returns the result of its calculations in the RES
%   structure array. RES(1) contains the input to the network, while
%   RES(2), RES(3), ... contain the output of each layer, from first
%   to last. Each entry has the following fields:
%
%   - `res(i+1).x`: the output of layer `i`. Hence `res(1).x` is the
%     network input.
%
%   - `res(i+1).aux_fwd`: any auxiliary output data of layer i during the
%      forward pass.
%
%   - `res(i).aux_bwd`: any auxiliary output data of layer i+1 during the
%      backward pass.
%
%   - `res(i+1).dzdx`: the derivative of the network output relative
%     to the output of layer `i`. In particular `res(1).dzdx` is the
%     derivative of the network output with respect to the network
%     input.
%
%   - `res(i+1).dzdw`: a cell array containing the derivatives of the
%     network output relative to the parameters of layer `i`. It can
%     be a cell array for multiple parameters.
%
%   ## The network format
%
%   The network is represented by the NET structure, which contains
%   two fields:
%
%   - `net.layers` is a cell array with the CNN layers.
%
%   - `net.meta` is a grab-bag of auxiliary application-dependent
%     information, including for example details on how to normalize
%     input data, the class names for a classifiers, or details of
%     the learning algorithm. The content of this field is ignored by
%     NET_EVAL().
%
%   NET_EVAL is aware of the following layers:
%
%   IMLOSS layer::
%     The imloss layer wraps NN_IMLOSS(). It has fields
%
%     - `layer.type` contains the string `'imloss'`.
%     - `layer.class` contains the ground-truth data.
%     - `layer.peakVal` contains the peakVal (e.g 255).
%     - `layer.loss_type` contains the string  `'psnr'` or `'l1'`.
%
%
%   CNLCF layer:
%     The CNLCF layer wraps cnlcf(). It has fields:
%
%     - `layer.type` contains the string `'cnlcf'.
%     - `layer.filters` is a cell array which contains the spatial filter
%        coefficients 
%     - `layer.weights` is a cell array that contains the weights for
%        the filter response normalization, the rbf-mixture, and the 
%        projection threshold constant alpha.
%     - `layer.learningRate` is set to a positive vector if the weights 
%        need to be learned. Otherwise is set to zero.
%     - `layer.rbf_means` contains the means.
%     - `layer.rbf_precision` contains the precision.
%     - `layer.stride` is the sampling stride.
%     - `layer.padSize` is the padding.
%     - `layer.Jacobian` contains a multidimensional array computed during
%        the forward pass.
%     - `layer.first_stage` if set to true then it indicates that this is
%        the first layer of the network.
%
%     The first function is called as
%
%          res(i+1) = layer.forward(layer, res(i), res(i+1))
%
%     where RES is the structure array specified before. The second function is
%     called as
%
%          res(i) = layer.backward(layer, res(i), res(i+1))
%
%     Note that the `layer` structure can contain additional custom
%     fields if needed.

opts.conserveMemory = false ;
opts.sync = false ;
opts.mode = 'normal' ;
opts.accumulate = false ;
opts.cudnn = true ;
opts.backPropDepth = +inf ;
opts.skipForward = false ;
opts.parameterServer = [] ;
opts.holdOn = false ;

%--Net auxiliary params (Specific for nlcf)--%
opts.netParams = struct('Obs',[], ...
                        'data_mu',[], ...
                        'step',[], ...
                        'origin',[], ...
                        'Nbrs_idx', [], ...
                        'Nbrs_weights', [], ...
                        'ATA', @(x)x, ...
                        'AT', @(x)x, ...
                        'identity', false);
%
% Obs : Indicates the input of the first stage of the network
% stdn : standard deviation for the noise distorting each image 
% in the batch
% data_mu : The data used for creating the look-up table in RBFs
% step : The step size for sampling the domain of the function that is
% approximated by the RBFs
% origin : Defines the lower end from which we start the sampling.
% Nbrs_idx : It is the output of misc.patchMatch applied on
% vl_nnpad(x,opts.padSize).
% Nbrs_weights :: Weights for collaborative filtering of patches.
% ---------------
opts = vl_argparse(opts, varargin);

n = numel(net.layers);
assert(opts.backPropDepth > 0, 'Invalid `backPropDepth` value (!>0)');
backPropLim = max(n - opts.backPropDepth + 1, 1);

if (nargin <= 2) || isempty(dzdy)
  doder = false ;
  if opts.skipForward
    error('net_eval:skipForwardNoBackwPass', ...
      '`skipForward` valid only when backward pass is computed.');
  end
else
  doder = true ;
end

if opts.cudnn
  cudnn = {'CuDNN'} ;
  bnormCudnn = {'NoCuDNN'} ; % ours seems slighty faster
else
  cudnn = {'NoCuDNN'} ;
  bnormCudnn = {'NoCuDNN'} ;
end

switch lower(opts.mode)
  case 'normal'
    testMode = false ;
  case 'test'
    testMode = true ;
  otherwise
    error('Unknown mode ''%s''.', opts. mode) ;
end

gpuMode = isa(x, 'gpuArray') ;

if nargin <= 3 || isempty(res)
  if opts.skipForward
    error('net_eval:skipForwardEmptyRes', ...
    'RES structure must be provided for `skipForward`.');
  end  
  res = struct(...
    'x', cell(1,n+1), ...
    'dzdx', cell(1,n+1), ...
    'dzdw', cell(1,n+1), ...
    'aux', cell(1,n+1), ... 
    'stats', cell(1,n+1), ...
    'time', num2cell(zeros(1,n+1)), ...
    'backwardTime', num2cell(zeros(1,n+1)));
end

if ~opts.skipForward
  res(1).x = x ;
end

if isempty(opts.netParams.Obs) % If Obs is empty then we assume 
  % that the distorted Observations match the input of the network.
  if isequal(net.layers{1}.type,'rgb2LumChrom')
    opts.netParams.Obs = misc.rgb2LumChrom(x,[],'scale',...
      net.layers{1}.scale,'Op',net.layers{1}.Op);
  else
    opts.netParams.Obs = x;
  end
end

clear x;

% -------------------------------------------------------------------------
%                                                              Forward pass
% -------------------------------------------------------------------------

for i=1:n
  if opts.skipForward, break; end;
  l = net.layers{i};
  res(i).time = tic;
  
  
  switch l.type
    
    case 'imloss'
      
      res(i+1).x = nn_imloss(checkInput(res(i).x), l.class, [], ...
        'peakVal',l.peakVal,'loss_type',l.loss_type);      
    
    case 'bnorm'
      if testMode
        res(i+1).x = vl_nnbnorm(checkInput(res(i).x), l.weights{1}, ...
          l.weights{2}, 'moments', l.weights{3}, 'epsilon', l.epsilon, ...
          bnormCudnn{:}) ;
      else
        res(i+1).x = vl_nnbnorm(checkInput(res(i).x), l.weights{1}, ...
          l.weights{2}, 'epsilon', l.epsilon, bnormCudnn{:}) ;
      end
      
    case 'clip'
      res(i+1).x = nn_clip(checkInput(res(i).x), l.lb, l.ub);     

    case 'rgb2LumChrom'
      res(i+1).x = misc.rgb2LumChrom(checkInput(res(i).x),[],...
        'scale',l.scale,'Op',l.Op,'cuDNN',cudnn{:});
      
    case 'LumChrom2rgb'
      res(i+1).x = misc.LumChrom2rgb(checkInput(res(i).x),[],...
        'scale',l.scale,'Op',l.Op,'cuDNN',cudnn{:});  
      if doder
        if iscell(res(i).x)
          res(i).x{end} = [];% We don't need this input for back-propagation.
        else
          res(i).x = [];
        end
      end
      
    case 'cnlcf'
      
      if doder
        [res(i+1).x,~,~,~,~,~,~,res(i+1).aux{1},res(i+1).aux{2}] = ...
          cnlcf(checkInput(res(i).x), opts.netParams.Obs, l.filters{1}, ...
          l.weights{1}, l.weights{2}, l.weights{3}, l.weights{4}, ...
          l.weights{5}, l.rbf_means, l.rbf_precision, l.weights{6}, [], ...
          'conserveMemory', false, 'stride', l.stride, 'padSize', ...
          l.padSize, 'cuDNN', cudnn{:}, 'data_mu', opts.netParams.data_mu, ...
          'step', opts.netParams.step, 'origin', opts.netParams.origin, ...
          'ATA',opts.netParams.ATA,'AT',opts.netParams.AT, 'identity',...
          opts.netParams.identity, 'shrink_type',l.shrink_type, 'lb', ...
          l.lb, 'ub', l.ub, 'Nbrs_idx', opts.netParams.Nbrs_idx, ...
          'Nbrs_weights', cto(l.patchWeighting,opts.netParams.Nbrs_weights));
      else
        res(i+1).x = cnlcf(checkInput(res(i).x), opts.netParams.Obs, ...
          l.filters{1}, l.weights{1}, l.weights{2}, l.weights{3}, ...
          l.weights{4}, l.weights{5}, l.rbf_means, l.rbf_precision, ...
          l.weights{6}, [], 'conserveMemory', true, 'stride', l.stride, ...
          'padSize', l.padSize, 'cuDNN', cudnn{:}, 'data_mu', ...
          opts.netParams.data_mu, 'step', opts.netParams.step, 'origin', ...
          opts.netParams.origin, 'ATA',opts.netParams.ATA,'AT', ...
          opts.netParams.AT, 'identity', opts.netParams.identity, ...
          'shrink_type',l.shrink_type, 'lb', l.lb, 'ub', l.ub, ...
          'Nbrs_idx', opts.netParams.Nbrs_idx, 'Nbrs_weights', ...
          cto(l.patchWeighting,opts.netParams.Nbrs_weights));
      end
      
    otherwise
      error('Unknown layer type ''%s''.', l.type) ;
  end
  
  % optionally forget intermediate results
  needsBProp = doder && i >= backPropLim;
  forget = opts.conserveMemory && ~needsBProp;  
  if i > 1
    lp = net.layers{i-1};
    forget = forget & ~strcmp(lp.type, 'imloss');
    if isfield(lp,'precious') 
      forget = forget & ~lp.precious; 
    end
  end

  if forget 
    res(i).x = [] ;
  end
  
  if gpuMode && opts.sync
    wait(gpuDevice) ;
  end
  res(i).time = toc(res(i).time) ;
end

if opts.conserveMemory && backPropLim > n % If there is not a backward pass
  % we delete all the intermediate results at the end of the forward pass.
  for i = 1:n
    res(i).x = [];
  end
end


% -------------------------------------------------------------------------
%                                                             Backward pass
% -------------------------------------------------------------------------
if doder
  res(n+1).dzdx = dzdy ;
  for i=n:-1:backPropLim
    l = net.layers{i} ;
    res(i).backwardTime = tic ;
    switch l.type
      
      case 'imloss'
        res(i).dzdx = nn_imloss(checkInput(res(i).x), l.class, ...
          res(i+1).dzdx, 'peakVal', l.peakVal, 'loss_type', l.loss_type);

      case 'bnorm'
        [res(i).dzdx, dzdw{1}, dzdw{2}, dzdw{3}] = ...
          vl_nnbnorm(checkInput(res(i).x), l.weights{1}, l.weights{2}, ...
          res(i+1).dzdx, 'epsilon', l.epsilon, bnormCudnn{:}) ;
        % multiply the moments update by the number of images in the batch
        % this is required to make the update additive for subbatches
        % and will eventually be normalized away
        dzdw{3} = dzdw{3} * size(res(i).x,4) ;        

      case 'clip'
        % Check if the output of the previous layer is a cell-array.
        res(i).dzdx = nn_clip(checkInput(res(i).x), l.lb, l.ub, ...
          res(i+1).dzdx);

      case 'rgb2LumChrom'
        res(i).dzdx = misc.rgb2LumChrom([],res(i+1).dzdx,...
          'scale',l.scale,'Op',l.Op,'cuDNN',cudnn{:});
        
      case 'LumChrom2rgb'
        res(i).dzdx = misc.LumChrom2rgb([],res(i+1).dzdx,...
          'scale',l.scale,'Op',l.Op,'cuDNN',cudnn{:});        
      
      case 'cnlcf'
        % We need to re-arrange the input of NLCF based on the
        % results stored in its output during the forward mode.
        
        input = {checkInput(res(i).x),{res(i+1).x{3},res(i+1).x{2}}, ...
          res(i+1).x{1}};    
        res(i+1).x(1:3) = [];
        
        [res(i).dzdx,dzdw{1},dzdw{2},dzdw{3},dzdw{4},dzdw{5},dzdw{6}] = ...
          cnlcf(input, opts.netParams.Obs, l.filters{1}, l.weights{1}, ...
          l.weights{2}, l.weights{3}, l.weights{4}, l.weights{5}, ...
          l.rbf_means, l.rbf_precision, l.weights{6}, res(i+1).dzdx, ...
          'stride', l.stride, 'padSize', l.padSize, 'cuDNN', cudnn{:}, ...
          'Jacobian', res(i+1).aux{1}, 'clipMask', res(i+1).aux{2}, ...
          'learningRate', l.learningRate, 'first_stage', l.first_stage, ...
          'data_mu', opts.netParams.data_mu, 'step', opts.netParams.step, ...
          'origin', opts.netParams.origin, 'ATA', opts.netParams.ATA, ...
          'AT', opts.netParams.AT, 'identity', opts.netParams.identity, ...
          'shrink_type', l.shrink_type, 'lb', l.lb, 'ub', l.ub, ...
          'Nbrs_idx', opts.netParams.Nbrs_idx, 'Nbrs_weights', ...
          cto(l.patchWeighting,opts.netParams.Nbrs_weights));
        
        clear input;
        
    end % layers
    
    switch l.type
      case {'cnlcf','bnorm'}
        if ~opts.accumulate
          res(i).dzdw = dzdw;
        else
          for j=1:numel(dzdw)
            res(i).dzdw{j} = res(i).dzdw{j} + dzdw{j};
          end
        end
        dzdw = [];
        if ~isempty(opts.parameterServer) && ~opts.holdOn
          for j = 1:numel(res(i).dzdw)
            opts.parameterServer.push(sprintf('l%d_%d',i,j),res(i).dzdw{j}) ;
            res(i).dzdw{j} = [] ;
          end
        end        
    end
    
    if ~isfield(net.layers{i},'precious')
      net.layers{i}.precious = false;
    end
    
    if opts.conserveMemory && ~net.layers{i}.precious && i ~= n
      res(i+1).dzdx = [];
      res(i+1).x=[];
      
      switch l.type
        case {'cnlcf'}
          res(i+1).aux=[];
      end
    end
    if gpuMode && opts.sync
      wait(gpuDevice);
    end
    res(i).backwardTime = toc(res(i).backwardTime);
  end
  if i > 1 && i == backPropLim && opts.conserveMemory && ~net.layers{i}.precious
    res(i).dzdx = [] ;
    res(i).x = [] ;
  end  
end

function x = checkInput(x)
% It checks if the input is a cell-array. If this is the case it returns
% the last element of the cell. Otherwise it does nothing.
while iscell(x)
  x = x{end};
end

% % In case the last entry of the cell is a cell itself
% while iscell(x)
%   x = x{end};
% end

% If the second input is isempty then the output equals to the first input.
% Otherwise the output equals to the second input.

function  argout = cto(expression,val_true,val_false)
% Matlab version of the conditional ternary operator : 
% expression ? val_true : val_false

if nargin < 3 
  val_false = [];
end

if expression
  argout = val_true;
else
  argout = val_false;
end

