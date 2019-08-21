# Data pre-processing module
# 
# Copyright (C) 2016-2018 by Xiaolei Lab
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


#' MVP, Memory-efficient, Visualization-enhanced, Parallel-accelerated
#'
#' Object 1: To perform GWAS using General Linear Model (GLM), Mixed Linear Model (MLM), and FarmCPU model
#' Object 2: To calculate kinship among individuals using Varaden method
#' Object 3: Estimate variance components using EMMA, FaST-LMM, and HE regression
#' Object 4: Generate high-quality figures
#' 
#' Build date: Aug 30, 2017
#' Last update: Dec 14, 2018
#' 
#' @author Lilin Yin, Haohao Zhang, and Xiaolei Liu
#' 
#' @param phe phenotype, n * 2 matrix, n is sample size
#' @param geno Genotype in bigmatrix format; m * n, m is marker size, n is sample size
#' @param map SNP map information, SNP name, Chr, Pos
#' @param K Kinship, Covariance matrix(n * n) for random effects, must be positive semi-definite
#' @param nPC.GLM number of PCs added as fixed effects in GLM
#' @param nPC.MLM number of PCs added as fixed effects in MLM
#' @param nPC.FarmCPU number of PCs added as fixed effects in FarmCPU
#' @param CV.GLM covariates added in GLM
#' @param CV.MLM covariates added in MLM
#' @param CV.FarmCPU covariates added in FarmCPU
#' @param REML a list contains ve and vg
#' @param priority speed or memory
#' @param ncpus number of cpus used for parallel
#' @param vc.method methods for estimating variance component("EMMA" or "HE" or "BRENT")
#' @param method the GWAS model, "GLM", "MLM", and "FarmCPU", models can be selected simutaneously, i.e. c("GLM", "MLM", "FarmCPU")
#' @param p.threshold if all p values generated in the first iteration are bigger than p.threshold, FarmCPU stops
#' @param QTN.threshold in second and later iterations, only SNPs with lower p-values than QTN.threshold have chances to be selected as pseudo QTNs
#' @param method.bin EMMA or FaSTLMM
#' @param bin.size window size in genome
#' @param bin.selection a vector, how many windows selected
#' @param maxLoop maximum number of iterations
#' @param permutation.threshold if use a permutation cutoff or not (bonferroni cutoff)
#' @param permutation.rep number of permutation replicates
#' @param bar if TRUE, the progress bar will be drawn on the terminal
#' @param col for color of points in each chromosome on manhattan plot
#' @param file.output whether to output files or not
#' @param file figure formats, "jpg", "tiff"
#' @param dpi resolution for output figures
#' @param threshold a cutoff line on manhattan plot, 0.05/marker size

#' @export
#' @return a m * 2 matrix, the first column is the SNP effect, the second column is the P values
#' Output: MVP.return$map - SNP map information, SNP name, Chr, Pos
#' Output: MVP.return$glm.results - p-values obtained by GLM method
#' Output: MVP.return$mlm.results - p-values obtained by MLM method
#' Output: MVP.return$farmcpu.results - p-values obtained by FarmCPU method
#'
#' @examples
#' phePath <- system.file("extdata", "07_other", "mvp.phe", package = "rMVP")
#' phenotype <- read.table(phePath, header=TRUE)
#' print(dim(phenotype))
#' genoPath <- system.file("extdata", "06_mvp-impute", "mvp.imp.geno.desc", package = "rMVP")
#' genotype <- attach.big.matrix(genoPath)
#' print(dim(genotype))
#' mapPath <- system.file("extdata", "07_other", "mvp.map", package = "rMVP")
#' map <- read.table(mapPath , head = TRUE)
#' 
#' mvp <- MVP(phe=phenotype, geno=genotype, map=map, maxLoop=3,
#'   method=c("GLM", "MLM", "FarmCPU"), file.output=FALSE, ncpus=1)
#' str(mvp)
#' 
#' file.remove(dir(pattern = "*.log"))
MVP <-
function(phe, geno, map, K=NULL, nPC.GLM=NULL, nPC.MLM=NULL, nPC.FarmCPU=NULL,
         CV.GLM=NULL, CV.MLM=NULL, CV.FarmCPU=NULL, REML=NULL, priority="speed", 
         ncpus=detectCores(logical = FALSE), vc.method=c("BRENT", "EMMA", "HE"), 
         method=c("GLM", "MLM", "FarmCPU"), p.threshold=NA, 
         QTN.threshold=0.01, method.bin="static", bin.size=c(5e5,5e6,5e7), 
         bin.selection=seq(10,100,10), maxLoop=10, permutation.threshold=FALSE, 
         permutation.rep=100, bar=TRUE, 
         col=c("dodgerblue4","olivedrab4","violetred","darkgoldenrod1","purple4"), 
         file.output=TRUE, file="jpg", dpi=300, threshold=0.05
) {
    now <- Sys.time()
    if (options("rMVP.OutputLog2File") == TRUE) {
        # get logfile name
        logfile <- paste("MVP", format(now, "%Y%m%d"), sep = ".")
        count <- 1
        while (file.exists(paste0(logfile, ".log"))) {
            logfile <- paste("MVP", format(now, "%Y%m%d"), count, sep = ".")
            count <- count + 1
        }
        logfile <- paste0(logfile, ".log")
        sink(logfile, split=TRUE)
    }
    
    R.ver <- Sys.info()[['sysname']]
    wind <- R.ver == 'Windows'
    linux <- R.ver == 'Linux'
    mac <- (!linux) & (!wind)
    r.open <- eval(parse(text = "!inherits(try(Revo.version,silent=TRUE),'try-error')"))
    
    
    if(wind) ncpus <- 1
    if(r.open && ncpus>1 && mac){
        Sys.setenv("VECLIB_MAXIMUM_THREADS" = "1")
    }
    
    MVP.Version(width = 60)
    message("Start:", as.character(now))
    if (options("rMVP.OutputLog2File") == TRUE) {
        message("The log has been output to the file:", logfile)
    }
    vc.method <- match.arg(vc.method)
    if(nrow(phe) != ncol(geno)) stop("The number of individuals in phenotype and genotype doesn't match!")
    #list -> matrix
    map <- as.matrix(map)
    na.index <- NULL
    if(!is.null(CV.GLM)){
        CV.GLM <- as.matrix(CV.GLM)
    if(nrow(CV.GLM) != ncol(geno)) stop("The number of individuals in covariates and genotype doesn't match!")
        na.index <- c(na.index, which(is.na(CV.GLM), arr.ind=TRUE)[, 1])
    }
    if(!is.null(CV.MLM)){
        CV.MLM <- as.matrix(CV.MLM)
        if(nrow(CV.MLM) != ncol(geno)) stop("The number of individuals in covariates and genotype doesn't match!")
       na.index <- c(na.index, which(is.na(CV.MLM), arr.ind=TRUE)[, 1])
    }
    if(!is.null(CV.FarmCPU)){
        CV.FarmCPU <- as.matrix(CV.FarmCPU)
        if(nrow(CV.FarmCPU) != ncol(geno)) stop("The number of individuals in covariates and genotype doesn't match!")
        na.index <- c(na.index, which(is.na(CV.FarmCPU), arr.ind=TRUE)[, 1])
    }
    na.index <- unique(na.index)
    
    #remove samples with missing phenotype
    seqTaxa = which(!is.na(phe[,2]))
    if(length(na.index) != 0) seqTaxa <- intersect(seqTaxa, c(1:nrow(phe))[-na.index])
    #file.exsits()
    if(length(seqTaxa) != length(phe[,2])){
        try(unlink(c("temp.geno.bin","temp.geno.desc")), silent=TRUE)
        remove_bigmatrix("temp")
        geno = deepcopy(
          x = geno,
          cols = seqTaxa,
          backingpath = getwd(),
          backingfile = "temp.geno.bin",
          descriptorfile = "temp.geno.desc"
        )
        phe = phe[seqTaxa,]
        if(!is.null(K)){K = K[seqTaxa, seqTaxa]}
        if(!is.null(CV.GLM)){CV.GLM = CV.GLM[seqTaxa,]}
        if(!is.null(CV.MLM)){CV.MLM = CV.MLM[seqTaxa,]}
        if(!is.null(CV.FarmCPU)){CV.FarmCPU = CV.FarmCPU[seqTaxa,]}
        rm(geno)
            gc()
            genoName <- "temp.geno.desc"
        geno <- attach.big.matrix(genoName)
        unlink(c("temp.geno.desc", "temp.geno.bin"))
    }
    #Data information
    m=nrow(geno)
    n=ncol(geno)
    message("Input data has ", n, " individuals, ", m, " markers")
    
    #initial results
    glm.results <- NULL
    mlm.results <- NULL
    farmcpu.results <- NULL
    
    #indicators for models
    glm.run <- "GLM" %in% method
    mlm.run <- "MLM" %in% method
    farmcpu.run <- "FarmCPU" %in% method
    
    if(!is.null(nPC.GLM)|!is.null(nPC.MLM)|!is.null(nPC.FarmCPU)){
        nPC <- max(nPC.GLM, nPC.MLM, nPC.FarmCPU)
        if(nPC < 3){
        	nPC <- 3
        }
    }else{
        nPC <- NULL
    }
    if(!is.null(K)){K <- as.matrix(K)}
    if(!is.null(nPC) | "MLM" %in% method){
        if(is.null(K)){
            K <- MVP.K.VanRaden(M=geno, priority=priority, cpu=ncpus)
        }
        message("Eigen Decomposition")
        eigenK <- eigen(K, symmetric=TRUE)
        if(!is.null(nPC)){
            ipca <- eigenK$vectors[, 1:nPC]
            message("Deriving PCs successfully")
        }
        if(("MLM" %in% method) & vc.method == "BRENT"){K <- NULL; gc()}
        if(!"MLM" %in% method){rm(eigenK); rm(K); gc()}
    }

    if (!is.null(nPC)) {

        #CV for GLM
        if(glm.run){
            if(!is.null(CV.GLM)){
                if(!is.null(nPC.GLM)){
                    CV.GLM <- cbind(ipca[,1:nPC.GLM], CV.GLM)
                }
            }else{
                CV.GLM <- ipca[,1:nPC.GLM]
            }
        }
        
        #CV for MLM
        if(mlm.run){
            if(!is.null(CV.MLM)){
                if(!is.null(nPC.MLM)){
                    CV.MLM <- cbind(ipca[,1:nPC.MLM], CV.MLM)
                }
            }else{
                CV.MLM <- ipca[,1:nPC.MLM]
            }
        }
        
        #CV for FarmCPU
        if(farmcpu.run){
            if(!is.null(CV.FarmCPU)){
                if(!is.null(nPC.FarmCPU)){
                    CV.FarmCPU <- cbind(ipca[,1:nPC.FarmCPU], CV.FarmCPU)
                }
            }else{
                CV.FarmCPU <- ipca[,1:nPC.FarmCPU]
            }
        }  
    }
  
    #GWAS
    message("|------------------------GWAS Start------------------------|")
    if(glm.run){
        message("General Linear Model (GLM) Start...")
        glm.results <- MVP.GLM(phe=phe, geno=geno, CV=CV.GLM, cpu=ncpus, bar=bar);gc()
        colnames(glm.results) <- c("effect", "se", paste(colnames(phe)[2],"GLM",sep="."))
        if(file.output) write.csv(cbind(map,glm.results), paste("MVP.",colnames(phe)[2],".GLM", ".csv", sep=""), row.names=FALSE)
    }

    if(mlm.run){
        message("Mixed Linear Model (MLM) Start...")
        mlm.results <- MVP.MLM(phe=phe, geno=geno, K=K, eigenK=eigenK, CV=CV.MLM, cpu=ncpus, bar=bar, vc.method=vc.method);gc()
        colnames(mlm.results) <- c("effect", "se", paste(colnames(phe)[2],"MLM",sep="."))
        if(file.output) write.csv(cbind(map,mlm.results), paste("MVP.",colnames(phe)[2],".MLM", ".csv", sep=""), row.names=FALSE)
    }
    
    if(farmcpu.run){
        message("FarmCPU Start...")
        farmcpu.results <- MVP.FarmCPU(phe=phe, geno=geno, map=map, CV=CV.FarmCPU, ncpus=ncpus, bar=bar, memo="MVP.FarmCPU", p.threshold=p.threshold, QTN.threshold=QTN.threshold, method.bin=method.bin, bin.size=bin.size, bin.selection=bin.selection, maxLoop=maxLoop)
        colnames(farmcpu.results) <- c("effect", "se", paste(colnames(phe)[2],"FarmCPU",sep="."))
        if(file.output) write.csv(cbind(map,farmcpu.results), paste("MVP.",colnames(phe)[2],".FarmCPU", ".csv", sep=""), row.names=FALSE)
    }
    
    MVP.return <- list(map=map, glm.results=glm.results, mlm.results=mlm.results, farmcpu.results=farmcpu.results)
    
    if(permutation.threshold){
        # set.seed(12345)
        i=1
            for(i in 1:permutation.rep){
            index = 1:nrow(phe)
            index.shuffle = sample(index,length(index),replace=FALSE)
            myY.shuffle = phe
            myY.shuffle[,2] = myY.shuffle[index.shuffle,2]
            #GWAS using t.test...
            myPermutation = MVP.GLM(phe=myY.shuffle[,c(1,2)], geno=geno, cpu=ncpus)
            pvalue = min(myPermutation[,2],na.rm=TRUE)
            if(i==1){
                    pvalue.final=pvalue
               }else{
                    pvalue.final=c(pvalue.final,pvalue)
            }
        }#end of permutation.rep
        permutation.cutoff = sort(pvalue.final)[ceiling(permutation.rep*0.05)]
        threshold = permutation.cutoff * m
    }
    message("Significant level: ", sprintf("%.6f", threshold/m))
    if(file.output){
        if(glm.run){
            index <- which(glm.results[, ncol(glm.results)] < threshold/m)
            if(length(index) != 0)  write.csv(cbind(map,glm.results)[index, ], paste("MVP.",colnames(phe)[2],".GLM_signal", ".csv", sep=""), row.names=FALSE)
        }
        if(mlm.run){
            index <- which(mlm.results[, ncol(mlm.results)] < threshold/m)
            if(length(index) != 0)  write.csv(cbind(map,mlm.results)[index, ], paste("MVP.",colnames(phe)[2],".MLM_signal", ".csv", sep=""), row.names=FALSE)
        }
        if(farmcpu.run){
            index <- which(farmcpu.results[, ncol(farmcpu.results)] < threshold/m)
            if(length(index) != 0)  write.csv(cbind(map,farmcpu.results)[index, ], paste("MVP.",colnames(phe)[2],".FarmCPU_signal", ".csv", sep=""), row.names=FALSE)
        }
    }
    if(file.output){
        message("|--------------------Visualization Start-------------------|")
        message("Phenotype distribution Plotting")
        MVP.Hist(phe=phe, file.type=file, col=col, dpi=dpi)
        #plot3D <- !is(try(library("rgl"),silent=TRUE), "try-error")
        plot3D <- TRUE
        if(!is.null(nPC)){
            MVP.PCAplot(
                ipca[,1:3],
                col=col,
                plot3D=plot3D,
                file=file,
                dpi=dpi,
            )
        }
        
        MVP.Report(
            MVP.return,
            col=col,
            plot.type=c("c","m","q","d"),
            file.output=TRUE,
            file=file,
            dpi=dpi,
            threshold=threshold/m,
        )

        if(sum(c(is.null(glm.results), is.null(mlm.results), is.null(farmcpu.results))) < 2) {
            MVP.Report(
                MVP.return,
                col=col,
                plot.type=c("m","q"),
                multracks=TRUE,
                file.output=TRUE,
                file=file,
                dpi=dpi,
                threshold=threshold/m
            )
        }
    }
    now <- Sys.time()
    message("Results are stored at Working Directory:", getwd())
    message("End:", as.character(now))
    print_accomplished(width = 60)
    
    if (options("rMVP.OutputLog2File") == TRUE) {
        sink()
    }
    
    return(MVP.return)
}#end of MVP function
