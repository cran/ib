# These functions are
# Copyright (C) 2020 S. Orso, University of Geneva
# All rights reserved.

ib.vglm <- function(object, thetastart=NULL, control=list(...), extra_param = FALSE,...){
  # controls
  control <- do.call("ibControl",control)

  # initial estimator:
  pi0 <- coef(object)

  if(!is.null(thetastart)){
    if(is.numeric(thetastart) && length(thetastart) == length(pi0)){
      t0 <- thetastart
    } else {
      stop("`thetastart` must be a numeric vector of the same length as
           parameter of interest.", call.=FALSE)
    }
  } else {
    t0 <- pi0
  }

  # test diff between thetas
  p <- p0 <- length(t0)
  test_theta <- control$tol + 1

  # iterator
  k <- 0L

  # create an environment for iterative bootstrap
  env_ib <- new.env(hash=F)

  # prepare data and formula for fit
  cl <- getCall(object)
  if(length(cl$formula)==1) cl$formula <- get(paste(cl$formula)) # get formula
  intercept_only <- cl$formula[[3]] == 1 # check for intercept only models
  # alternatively: intercept_only <- object@misc$intercept.only
  mf <- model.framevlm(object) # ? problem with mf <- model.frame(object)
  mt <- attr(mf, "terms")
  if(!intercept_only){
    x <- if(!is.empty.model(mt)) model.matrix(mt, mf, attr(mf,"contrasts"))
    # x <- model.matrixvlm(object)
    # remove intercept from design
    # check if model has an intercept
    has_intercept <- has.intercept(object)
    if(has_intercept){
      # remove intercept from design
      x <- x[,!grepl("Intercept",colnames(x))]
      cl$formula <- quote(y~x)
    } else {
      cl$formula <- quote(y~x-1)
    }
  } else {
    cl$formula <- quote(y~1)
  }
  cl$data <- NULL
  o <- as.vector(model.offset(mf))
  if(!is.null(o)) assign("o",o,env_ib)
  # add an offset
  if(!is.null(o)) cl$offset <- quote(o)
  # FIXME: add support for subset, na.action, start,
  #        etastart, mustart, contrasts, constraints
  n <- nrow(mf)
  w <- model.weights(mf)
  if(!length(w)){
    w <- rep_len(1, n)
  } else {
    cl$weights <- quote(w)
    assign("w",w,env_ib)
  }
  if(is.null(cl$etastart)) etastart <- NULL

  # copy the object
  tmp_object <- object

  # initial value
  diff <- rep(NA_real_, control$maxit)

  # Iterative bootstrap algorithm:
  while(test_theta > control$tol && k < control$maxit){
    # browser()
    # update initial estimator
    slot(tmp_object, "coefficients") <- t0[1:p0]
    sim <- simulation(tmp_object,control)
    tmp_pi <- matrix(NA_real_,nrow=p,ncol=control$H)
    for(h in seq_len(control$H)){
      assign("y",sim[,h],env_ib)
      # FIXME: deal with warnings from vglm.fitter
      # fit_tmp <- eval(cl,env_ib)
      fit_tmp <- tryCatch(error = function(cnd) NULL, {eval(cl,env_ib)})
      if(is.null(fit_tmp)) next
      tmp_pi[1:p0,h] <- coef(fit_tmp)
    }
    pi_star <- control$func(tmp_pi)

    # update value
    delta <- pi0 - pi_star
    t1 <- t0 + delta

    # test diff between thetas
    test_theta <- sum(delta^2)
    if(k>0) diff[k] <- test_theta

    # initialize test
    if(!k) tt_old <- test_theta+1

    # Alternative stopping criteria, early stop :
    if(control$early_stop){
      if(tt_old <= test_theta){
        warning("Algorithm stopped because the objective function does not reduce")
        break
      }
    }

    # Alternative stopping criteria, "statistically flat progress curve" :
    if(k > 10L){
      try1 <- diff[k:(k-10)]
      try2 <- k:(k-10)
      if(var(try1)<=1e-3) break
      mod <- lm(try1 ~ try2)
      if(summary(mod)$coefficients[2,4] > 0.2) break
    }

    # update increment
    k <- k + 1L

    # Print info
    if(control$verbose){
      cat("Iteration:",k,"Norm between theta_k and theta_(k-1):",test_theta,"\n")
    }

    # update theta
    t0 <- t1
  }
  # warning for reaching max number of iterations
  if(k>=control$maxit) warning("maximum number of iteration reached")

  # update vglm object
  extra <- slot(object, "extra")
  fam <- slot(object, "family")
  y <- slot(object, "y")
  M <- slot(object,"misc")$M
  # w <- c(slot(object, "prior.weights"))
  # w <- drop(weights(object, "prior"))
  # if(!length(w)==0) w <- rep_len(1,n)
  eval(slot(fam,"initialize")) # initialize different parameters (among which M)
  eta <- predictvglm(tmp_object)
  mu <- slot(fam,"linkinv")(eta, extra)
  u <- eval(slot(fam,"deriv"))
  W <- eval(slot(fam,"weight"))

  U <- vchol(W, M, n, silent = TRUE)
  tvfor <- vforsub(U, as.matrix(u), M, n)
  res <- vbacksub(U, tvfor, M, n)

  if(.hasSlot(fam, "deviance") && !is.null(body(slot(fam,"deviance"))))
    tmp_object@criterion$deviance <- slot(fam,"deviance")(mu,y,w,residuals=FALSE,eta,extra)
  if(.hasSlot(fam, "loglikelihood") && !is.null(body(slot(fam,"loglikelihood"))))
    tmp_object@criterion$loglikelihood <- slot(fam,"loglikelihood")(mu,y,w,residuals=FALSE,eta,extra)

  slot(tmp_object, "predictors") <- as.matrix(eta)
  slot(tmp_object, "fitted.values") <- as.matrix(mu)
  slot(tmp_object, "residuals") <- as.matrix(res)
  slot(tmp_object, "call") <- slot(object,"call")

  # additional metadata
  ib_extra <- list(
    iteration = k,
    of = sqrt(drop(crossprod(delta))),
    estimate = t0,
    test_theta = test_theta,
    boot = tmp_pi)

  new("IbVglm",
      object = tmp_object,
      ib_extra = ib_extra)
}

#' @rdname ib
#' @details
#' For \link[VGAM]{vglm}, \code{extra_param} is currently not used.
#' Indeed, the philosophy of a vector generalized linear model is to
#' potentially model all parameters of a distribution with a linear predictor.
#' Hence, what would be considered as an extra parameter in \code{\link[stats]{glm}}
#' for instance, may already be captured by the default \code{coefficients}.
#' However, correcting the bias of a \code{coefficients} does not imply
#' that the bias of the parameter of the distribution is corrected
#' (by \href{https://en.wikipedia.org/wiki/Jensen's_inequality}{Jensen's inequality}),
#' so we may use this feature in a future version of the package.
#' Note that we currently only support distributions
#' with a \code{simslot} (see \code{\link[VGAM]{simulate.vlm}}).
#' @example /inst/examples/eg_vglm.R
#' @seealso \code{\link[VGAM]{vglm}}
#' @importFrom VGAM Coef has.intercept model.framevlm predictvglm vbacksub vchol vglm vforsub
#' @importFrom methods slot `slot<-` .hasSlot
#' @importFrom stats model.weights
#' @export
setMethod("ib", className("vglm", "VGAM"),
          definition = ib.vglm)

# inspired from VGAM::simulate.vlm
#' @importFrom VGAM familyname
simulation.vglm <- function(object, control=list(...), extra_param = NULL, ...){
  control <- do.call("ibControl",control)

  fam <- slot(object, "family")
  if(is.null(body(slot(fam, "simslot"))))
    stop(paste0("simulation not implemented for family ", familyname(object)), call.=FALSE)

  set.seed(control$seed)
  if(!exists(".Random.seed", envir = .GlobalEnv)) runif(1)

  # user-defined simulation method
  if(!is.null(control$sim)){
    sim <- control$sim(object, control, extra_param, ...)
    return(sim)
  }

  sim <- matrix(slot(fam, "simslot")(object,control$H), ncol = control$H)

  if(control$cens) sim <- censoring(sim,control$right,control$left)
  if(control$mis) sim <- missing_at_random(sim, control$prop)
  if(control$out) sim <- outliers(sim, control$eps, control$G)
  sim
}

#' @title Simulation for vector generalized linear model regression
#' @description simulation method for class \linkS4class{IbVglm}
#' @param object an object of class \linkS4class{IbVglm}
#' @param control a \code{list} of parameters for controlling the iterative procedure
#' (see \code{\link{ibControl}}).
#' @param extra_param \code{NULL} by default; extra parameters to pass to simulation.
#' @param ... further arguments
#' @export
setMethod("simulation", signature = className("vglm","VGAM"),
          definition = simulation.vglm)
