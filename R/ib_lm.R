# These functions are
# Copyright (C) 2020 S. Orso, University of Geneva
# All rights reserved.

ib.lm <- function(object, thetastart=NULL, control=list(...), extra_param = FALSE, ...){
  # controls
  control <- do.call("ibControl",control)

  # initial estimator:
  pi0 <- coef(object)

  if(extra_param) pi0 <- c(pi0, sigma(object))

  if(!is.null(thetastart)){
    if(is.numeric(thetastart) && length(thetastart) == length(pi0)){
      t0 <- thetastart
    } else {
      stop("`thetastart` must be a numeric vector of the same length as parameter
           of interest.", call.=FALSE)
    }
  } else {
    t0 <- pi0
  }


  # test diff between thetas
  p <- p0 <- length(t0)
  if(extra_param) p0 <- p - 1L
  test_theta <- control$tol + 1

  # iterator
  k <- 0L

  # create an environment for iterative bootstrap
  env_ib <- new.env(hash=F)

  # prepare data and formula for fit
  cl <- getCall(object)
  if(length(cl$formula)==1) cl$formula <- get(paste(cl$formula)) # get formula
  intercept_only <- cl$formula[[3]] == 1 # check for intercept only models
  mf <- model.frame(object)
  mt <- terms(object)
  if(!intercept_only){
    x <- if(!is.empty.model(mt)) model.matrix(mt, mf, object$contrasts)
    # check if model has an intercept
    has_intercept <- attr(mt,"intercept")
    if(has_intercept){
      # remove intercept from design
      x <- x[,!grepl("Intercept",colnames(x))]
      cl$formula <- quote(y~x)
    } else {
      cl$formula <- quote(y~x-1)
    }
    assign("x",x,env_ib)
  } else{
    cl$formula <- quote(y~1)
  }
  o <- as.vector(model.offset(mf))
  if(!is.null(o)) assign("o",o,env_ib)
  cl$data <- NULL
  # add an offset
  if(!is.null(o)) cl$offset <- quote(o)

  # copy the object
  tmp_object <- object

  # initial value
  diff <- rep(NA_real_, control$maxit)
  if(!extra_param) std <- NULL

  # Iterative bootstrap algorithm:
  while(test_theta > control$tol && k < control$maxit){

    # update initial estimator
    tmp_object$coefficients <- t0[1:p0]
    if(extra_param) std <- t0[p]
    sim <- simulation(tmp_object,control,std)
    tmp_pi <- matrix(NA_real_,nrow=p,ncol=control$H)
    for(h in seq_len(control$H)){
      assign("y",sim[,h],env_ib)
      fit_tmp <- tryCatch(error = function(cnd) NULL, {eval(cl,env_ib)})
      if(is.null(fit_tmp)) next
      tmp_pi[1:p0,h] <- coef(fit_tmp)
      if(extra_param) tmp_pi[p,h] <- sigma(fit_tmp)
    }
    pi_star <- control$func(tmp_pi)

    # update value
    delta <- pi0 - pi_star
    t1 <- t0 + delta
    if(extra_param && control$constraint) t1[p] <- exp(log(t0[p]) + log(pi0[p]) - log(pi_star[p]))

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

  tmp_object$fitted.values <- predict.lm(tmp_object)
  tmp_object$residuals <- unname(model.frame(object))[,1] - tmp_object$fitted.values
  tmp_object$call <- object$call

  # additional metadata
  ib_extra <- list(
    iteration = k,
    of = sqrt(drop(crossprod(delta))),
    estimate = t0,
    test_theta = test_theta,
    boot = tmp_pi)

  new("IbLm",
      object = tmp_object,
      ib_extra = ib_extra)
}

#' @rdname ib
#' @details
#' For \link[stats]{lm}, if \code{extra_param=TRUE}: the variance of the residuals is
#' also corrected. Note that using the \code{ib} is not useful as coefficients
#' are already unbiased, unless one considers different
#' data generating mechanism such as censoring, missing values
#' and outliers (see \code{\link{ibControl}}).
#' @example /inst/examples/eg_lm.R
#' @seealso \code{\link[stats]{lm}}
#' @importFrom stats lm predict.lm model.matrix
#' @export
setMethod("ib", signature = className("lm","stats"),
          definition = ib.lm)

# inspired from stats::simulate.lm
#' @importFrom stats fitted sigma rnorm runif simulate
simulation.lm <- function(object, control=list(...), std=NULL, ...){
  control <- do.call("ibControl",control)

  set.seed(control$seed)
  if(!exists(".Random.seed", envir = .GlobalEnv)) runif(1)

  # user-defined simulation method
  if(!is.null(control$sim)){
    sim <- control$sim(object, control, std, ...)
    return(sim)
  }

  ftd <- fitted(object)
  n <- length(ftd)
  ntot <- n * control$H
  if(is.null(std)) std <- sigma(object)
  sim <- matrix(ftd + rnorm(ntot,sd=std), ncol=control$H)
  if(control$cens) sim <- censoring(sim,control$right,control$left)
  if(control$mis) sim <- missing_at_random(sim, control$prop)
  if(control$out) sim <- outliers(sim, control$eps, control$G)
  sim
}

#' @title Simulation for linear regression
#' @description simulation method for class \linkS4class{IbLm}
#' @param object an object of class \linkS4class{IbLm}
#' @param control a \code{list} of parameters for controlling the iterative procedure
#' (see \code{\link{ibControl}}).
#' @param std \code{NULL} by default; standard deviation to pass to simulation.
#' @param ... further arguments
#' @export
setMethod("simulation", signature = className("lm","stats"),
          definition = simulation.lm)
