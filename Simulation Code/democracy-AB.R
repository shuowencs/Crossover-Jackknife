# 2/14/2021 Shuowen Chen
# A script to implement Arellano-Bond for calibrated democracy simulation
library(foreign)
library(plm)
library(sandwich)
library(boot)


# Nonparametric bootstrap
data.rg <- function(data, mle) {
  N <- length(unique(data$id))
  T <- length(unique(data$year))
  ids <- kronecker(sample.int(N, N, replace = TRUE), rep(1, T))
  data_b <- data[(ids - 1)*T + rep(c(1:T), N), ]
  data_b$id <- kronecker(c(1:N), rep(1, T))
  data_b$year <- rep(c(1:T), N)
  data_b <- data.frame(data_b)
  data_b <- pdata.frame(data_b, index = c("id", "year"))
  return(data_b)
}

# Panel weighted bootstrap
data_wb <- function(data, mle) {
  # number of states
  n <- length(unique(data$id))
  t <- length(unique(data$year))
  # Exponential weights
  multipliers <- rexp(n)
  # For each state, weight is the same for all dates
  weights <- rep(multipliers/sum(multipliers), each = t)
  # Add to the data and treat it as sampling weight
  data$weights <- weights
  return(data)
}

# Estimators to be computed in each calibration and bootstrap estimation
estimator2 <- function(data, form) {
  # Fixed Effects
  form_ab <- lgdp ~ dem + lag(lgdp, 1:4) | lag(lgdp, 2:99) + lag(dem, 1:99)
  # Arellano-Bond (pgmm in plm package)
  ab <- pgmm(form_ab, data, model = "twosteps", effect = "twoways")
  coefs_ab <- coef(ab) 
  HCV_coefs <- vcovHC(ab, cluster = 'group')
  # Clustered std errors
  cse_ab <- sqrt(diag(HCV_coefs))
  # Long run effect estimator and se
  lr_ab <- coefs_ab[1]/(1 - sum(coefs_ab[2:5]))
  jac_lr <- c(1, rep(lr_ab, 4))/(1 - sum(coefs_ab[2:5]))
  cse_lr_ab <- sqrt(t(jac_lr) %*% HCV_coefs[1:5, 1:5] %*% jac_lr)
  
  return(c(coefs_ab[1:5], cse_ab[1:5], lr_ab, cse_lr_ab))
  
}

# A function that calls computes bootstrap standard errors within in simulation
bse <- function(data, fm, ncores, btimes, bseed) {
  # store seeds set in the global environment
  old <- .Random.seed
  # upon exiting the function environment, 
  # restore to the original seed
  on.exit({.Random.seed <<- old})
  # within this function environment, set
  # the new seed
  set.seed(bseed, kind = "L'Ecuyer-CMRG")
  result <- boot(data = data, statistic = estimator2, sim = "parametric", 
                 ran.gen = data.rg, mle = 0, form = fm, 
                 parallel = "multicore", ncpus = ncores, R = btimes)
  result <- structure(vapply(result$t, as.double, numeric(1)), 
                      dim = dim(result$t))
  se <- apply(result, 2, function(x) {
    return((quantile(x, .75, na.rm = TRUE) - 
              quantile(x, .25, na.rm = TRUE))/(qnorm(.75) - qnorm(.25)))
  })
  return(se)
}

bsew <- function(data, fm, ncores, btimes, bseed) {
  # store seeds set in the global environment
  old <- .Random.seed
  # upon exiting the function environment, 
  # restore to the original seed
  on.exit({.Random.seed <<- old})
  # within this function environment, set
  # the new seed
  set.seed(bseed, kind = "L'Ecuyer-CMRG")
  result <- boot(data = data, statistic = estimator2, sim = "parametric", 
                 ran.gen = data_wb, mle = 0, form = fm, 
                 parallel = "multicore", ncpus = ncores, R = btimes)
  result <- structure(vapply(result$t, as.double, numeric(1)), 
                      dim = dim(result$t))
  se <- apply(result, 2, function(x) {
    return((quantile(x, .75, na.rm = TRUE) - 
              quantile(x, .25, na.rm = TRUE))/(qnorm(.75) - qnorm(.25)))
  })
  return(se)
}

# statistics to be computed in each bootstrap draw 
bootstat <- function(data, formula, ncores, btimes, bseed){
  bestimate <- estimator2(data, formula)
  se <- bse(data, formula, ncores, btimes, bseed)
  return(c(bestimate, se))
}

bootstatw <- function(data, formula, ncores, btimes, bseed){
  bestimate <- estimator2(data, formula)
  se <- bsew(data, formula, ncores, btimes, bseed)
  return(c(bestimate, se))
}

########## Calibration
data <- read.dta("democracy-balanced-l4.dta")
# claim to be panel
data <- pdata.frame(data, index = c("id", "year"))
# add lagged dependent variables
data$l1lgdp <- lag(data$lgdp, 1)
data$l2lgdp <- lag(data$lgdp, 2) 
data$l3lgdp <- lag(data$lgdp, 3) 
data$l4lgdp <- lag(data$lgdp, 4) 
form <- lgdp ~ dem + l1lgdp + l2lgdp + l3lgdp + l4lgdp + 
  factor(year) + factor(id)
fe_fit <- lm(form, data, x = TRUE)
index <- fitted.values(fe_fit) - coef(fe_fit)[3]*fe_fit$x[, 3] - 
  coef(fe_fit)[4]*fe_fit$x[, 4] - coef(fe_fit)[5]*fe_fit$x[, 5] - 
  coef(fe_fit)[6]*fe_fit$x[, 6]
sigma <- sqrt(sum(fe_fit$residuals^2)/fe_fit$df.residual)
coefs0 <- fe_fit$coefficients
lr0 <- coefs0[2]/(1 - sum(coefs0[3:6]))
T <- length(levels(data$year)) - 4 # takes out 4 lags of obs
N <- length(levels(data$id))



# Generate simulated data


dgp <- function(data, mle) {
  y <- matrix(0, nrow = T + 4, ncol = N)
  # set the initial 4 obs for each unit as the original data
  for (t in 1:4) y[t, ] <- data[(t + c(0:(N - 1))*(T + 4)), 6]
  index <- matrix(index, nrow = T, ncol = N)
  # use estimated coefficient to construct data
  for (t in 5:(T + 4)) {
    y[t, ] <- index[t - 4, ] + coefs0["l1lgdp"]*y[t - 1, ] + 
      coefs0["l2lgdp"]*y[t - 2, ] + coefs0["l3lgdp"]*y[t - 3, ] + 
      coefs0["l4lgdp"]*y[t - 4, ] + rnorm(N, mean = 0, sd = sigma)
  }
  y <- matrix(y, ncol = 1)
  data_b <- data.frame(id = kronecker(sample(N), rep(1, T + 4)), 
                       year = kronecker(rep(1, N), c(1:(T + 4))), lgdp = y, 
                       dem = data[, "dem"])
  data_b <- pdata.frame(data_b, index = c("id", "year"))
  data_b$l1lgdp <- lag(data_b$lgdp, 1)
  data_b$l2lgdp <- lag(data_b$lgdp, 2) 
  data_b$l3lgdp <- lag(data_b$lgdp, 3) 
  data_b$l4lgdp <- lag(data_b$lgdp, 4)
  return(data_b)
}


##########
time_cal <- 500 # number of simulations
core <- 28
seed_bse <- 13 # seed for bootstrap standard error estimation
set.seed(88, kind = "L'Ecuyer-CMRG") # seed for calibration
parallel::mc.reset.stream()
bd <- boot(data = data, statistic = bootstat, sim = "parametric", mle = 0, 
           formula = form, ncores = core, btimes = 200, bseed = seed_bse,
           ran.gen = dgp, R = time_cal, ncpus = core)

#set.seed(88, kind = "L'Ecuyer-CMRG") # seed for calibration
#parallel::mc.reset.stream()
#bdw <- boot(data = data, statistic = bootstatw, sim = "parametric", mle = 0, 
#           formula = form, ncores = core, btimes = 200, bseed = seed_bse,
#           ran.gen = dgp, R = time_cal, ncpus = core)

est_dem <- bd$t[,1]
est_l1lgdp <- bd$t[,2]
est_l2lgdp <- bd$t[,3]
est_l3lgdp <- bd$t[,4]
est_l4lgdp <- bd$t[,5]
est_lr <- bd$t[,11]
est_cse <- bd$t[,6:10]
est_cse_lr <- bd$t[,12]

bse_dem <- bd$t[,13]
bse_l1lgdp <- bd$t[,14]
bse_l2lgdp <- bd$t[,15]
bse_l3lgdp <- bd$t[,16]
bse_l4lgdp <- bd$t[,17]
bse_lr <- bd$t[,23]

est_demw <- bdw$t[,1]
est_l1lgdpw <- bdw$t[,2]
est_l2lgdpw <- bdw$t[,3]
est_l3lgdpw <- bdw$t[,4]
est_l4lgdpw <- bdw$t[,5]
est_lrw <- bdw$t[,11]
est_csew <- bdw$t[,6:10]
est_cse_lrw <- bdw$t[,12]

bse_demw <- bdw$t[,13]
bse_l1lgdpw <- bdw$t[,14]
bse_l2lgdpw <- bdw$t[,15]
bse_l3lgdpw <- bdw$t[,16]
bse_l4lgdpw <- bdw$t[,17]
bse_lrw <- bdw$t[,23]

table_simulation <- function(est, bse, ase, est0, 
                             app = c("dem", "lfp")) {
  app <- match.arg(app)
  tab <- matrix(0, nrow = 1, ncol = 9)
  colnames(tab) <- c('Bias', 'Std Dev', 'RMSE', 'BSE/SD', 
                     'ASE/SD', 'p.95 (BSE)', 'p.95 (ASE)', 
                     'Length (BSE)', 'Length (ASE)')
  tab[, 1] <- 100*(mean(est)/est0 - 1)
  tab[, 2] <- 100*sd(est/est0)
  tab[, 3] <- 100*sqrt((mean((est/est0 - 1)^2)))
  tab[, 4] <- mean(bse)/sd(est)
  tab[, 5] <- mean(ase)/sd(est)
  tab[, 6] <- mean((est + qnorm(.05/2)*bse <= est0) & 
                      (est + qnorm(1 - .05/2)*bse >= est0))
  tab[, 7] <- mean((est + qnorm(.05/2)*ase <= est0) & 
                      (est + qnorm(1 - .05/2)*ase >= est0))
  tab[, 8] <- 2*qnorm(1 - .05/2)*mean(bse)/abs(est0)
  tab[, 9] <- 2*qnorm(1 - .05/2)*mean(ase)/abs(est0)
  return(tab)
}

dem_co <- table_simulation(est_dem, bse_dem, est_cse[, 1], coefs0[2])
l1lgdp_co <- table_simulation(est_l1lgdp, bse_l1lgdp, est_cse[, 2], coefs0[3])
l2lgdp_co <- table_simulation(est_l2lgdp, bse_l2lgdp, est_cse[, 3], coefs0[4])
l3lgdp_co <- table_simulation(est_l3lgdp, bse_l3lgdp, est_cse[, 4], coefs0[5])
l4lgdp_co <- table_simulation(est_l4lgdp, bse_l4lgdp, est_cse[, 5], coefs0[6])
lr_co <- table_simulation(est_lr, bse_lr, est_cse_lr, lr0)

dem_cow <- table_simulation(est_demw, bse_demw, est_cse[, 1], coefs0[2])
l1lgdp_cow <- table_simulation(est_l1lgdpw, bse_l1lgdpw, est_cse[, 2], coefs0[3])
l2lgdp_cow <- table_simulation(est_l2lgdpw, bse_l2lgdpw, est_cse[, 3], coefs0[4])
l3lgdp_cow <- table_simulation(est_l3lgdpw, bse_l3lgdpw, est_cse[, 4], coefs0[5])
l4lgdp_cow <- table_simulation(est_l4lgdpw, bse_l4lgdpw, est_cse[, 5], coefs0[6])
lr_cow <- table_simulation(est_lrw, bse_lrw, est_cse_lr, lr0)
######## Save the workspace
save.image(file = "democracyab.RData")
