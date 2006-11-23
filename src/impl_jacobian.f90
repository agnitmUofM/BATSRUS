!^CFG COPYRIGHT UM
!^CFG FILE IMPLICIT
subroutine impl_jacobian(implBLK,JAC)

  ! Calculate Jacobian matrix for block implBLK:
  !
  !    JAC = I - dt*beta*dR/dw
  !
  ! using 1st order Rusanov scheme for the residual RES:
  !
  !    R_i = 1./Dx*[                 -(Fx_i+1/2 - Fx_i-1/2 )
  !                + 0.5*cmax_i+1/2 * (W_i+1    - W_i      )
  !                + 0.5*cmax_i-1/2 * (W_i-1    - W_i      )
  !                + 0.5*Q_i        * (Bx_i+1   - Bx_i-1   ) ]
  !         +1./Dy*[...]
  !         +1./Dz*[...]
  !         +S
  !
  ! where W contains the conservative variables, 
  ! Fx, Fy, Fz are the fluxes, cmax is the maximum speed,
  ! Q are the coefficients B, U and U.B in the Powell source terms, and
  ! S are the local source terms.
  !
  !    Fx_i+1/2 = 0.5*(FxL_i+1/2 + FxR_i+1/2)
  !
  ! For first order scheme 
  !
  !    FxL_i+1/2 = Fx[ W_i  , B0_i+1/2 ]
  !    FxR_i+1/2 = Fx[ W_i+1, B0_i+1/2 ]
  !
  ! We neglect terms containing d(cmax)/dW, and obtain a generalized eq.18:
  !
  ! Main diagonal stencil==1:
  !    dR_i/dW_i   = 0.5/Dx*[ (dFxR/dW-cmax)_i-1/2 - (dFxL/dW+cmax)_i+1/2 ]
  !                + 0.5/Dy*[ (dFyR/dW-cmax)_j-1/2 - (dFyL/dW+cmax)_j+1/2 ]
  !                + 0.5/Dz*[ (dFzR/dW-cmax)_k-1/2 - (dFzL/dW+cmax)_k+1/2 ]
  !                + dQ/dW_i*divB
  !                + dS/dW
  !
  ! Subdiagonal stencil==2:
  !    dR_i/dW_i-1 = 0.5/Dx* [ (dFxL/dW+cmax)_i-1/2
  !                           - Q_i*dBx_i-1/dW_i-1 ]
  ! Superdiagonal stencil==3:
  !    dR_i/dW_i+1 = 0.5/Dx* [-(dFxR/dW-cmax)_i+1/2
  !                           + Q_i*dBx_i+1/dW_i+1 ]
  !
  ! and similar terms for stencil=4,5,6,7.
  ! 
  ! The partial derivatives are calculated numerically 
  ! (except for the trivial dQ/dW and dB/dW terms):
  !
  !  dF_iw/dW_jw = [F_iw(W + eps*W_jw) - F_iw(W)] / eps
  !  dS_iw/dW_jw = [S_iw(W + eps*W_jw) - S_iw(W)] / eps

  use ModProcMH
  use ModMain
  use ModvarIndexes
  use ModAdvance, ONLY : &
       B0xFace_x_BLK,B0yFace_x_BLK,B0zFace_x_BLK, &
       B0xFace_y_BLK,B0yFace_y_BLK,B0zFace_y_BLK, &
       B0xFace_z_BLK,B0yFace_z_BLK,B0zFace_z_BLK, &
       time_BLK
  use ModGeometry, ONLY : dx_BLK,dy_BLK,dz_BLK,dxyz,true_cell, &
       FaceAreaI_DFB, FaceAreaJ_DFB, FaceAreaK_DFB
  use ModImplicit
  use ModHallResist, ONLY: UseHallResist, hall_factor
  use ModGeometry, ONLY: vInv_CB, UseCovariant
  implicit none

  integer, intent(in) :: implBLK
  real,    intent(out):: JAC(nw,nw,nI,nJ,nK,nstencil)

  integer :: iBLK
  real, dimension(nI,nJ,nK,nw)                :: qwk      , weps
  real, dimension(nI+1,nJ+1,nK+1,nw,ndim)     :: fLface   , fRface
  real, dimension(nI+1,nJ+1,nK+1)             :: fepsLface, fepsRface, &
       dfdwLface, dfdwRface
  real, dimension(nI,nJ,nK,nw)                :: qS, qSeps, Qpowell
  real :: DivB(nI,nJ,nK), Current_D(nDim)
  real :: B0face(nI+1,nJ+1,nK+1,nDim,nDim), cmaxFace(nI+1,nJ+1,nK+1,nDim)

  real   :: qeps, coeff
  logical:: divbsrc, UseDivbSource0
  integer:: i,j,k,i1,i2,i3,j1,j2,j3,k1,k2,k3,istencil,iw,jw,idim,qj

  logical :: oktest, oktest_me

  real :: FluxLeft_FVD(nI+1,nJ+1,nK+1,nW,nDim) ! Unperturbed left flux
  real :: FluxRight_FVD(nI,nJ,nK,nW,nDim)      ! Unperturbed right flux
  real :: FluxEpsLeft_FV(nI+1,nJ+1,nK+1,nW)    ! Perturbed left flux
  real :: FluxEpsRight_FV(nI,nJ,nK,nW)         ! Perturbed right flux
  real :: FaceArea_F(nI, nJ, nK)               ! Only the inner faces

  integer :: i_D(3), ii, jj, kk
  !----------------------------------------------------------------------------

  if(iProc==PROCtest.and.implBLK==implBLKtest)then
     call set_oktest('impl_jacobian',oktest, oktest_me)
  else
     oktest=.false.; oktest_me=.false.
  end if

  qeps=sqrt(JacobianEps)

  divbsrc= UseDivbSource

  ! Extract state for this block
  qwk = w_k(1:nI,1:nJ,1:nK,1:nw,implBLK)
  iBLK = impl2iBLK(implBLK)
  dxyz(1)=dx_BLK(iBLK); dxyz(2)=dy_BLK(iBLK); dxyz(3)=dz_BLK(iBLK)

  B0face(1:nI+1,1:nJ  ,1:nK  ,x_,x_)=B0xFace_x_BLK(1:nI+1,1:nJ,1:nK,iBLK)
  B0face(1:nI+1,1:nJ  ,1:nK  ,y_,x_)=B0yFace_x_BLK(1:nI+1,1:nJ,1:nK,iBLK)
  B0face(1:nI+1,1:nJ  ,1:nK  ,z_,x_)=B0zFace_x_BLK(1:nI+1,1:nJ,1:nK,iBLK)
  B0face(1:nI  ,1:nJ+1,1:nK  ,x_,y_)=B0xFace_y_BLK(1:nI,1:nJ+1,1:nK,iBLK)
  B0face(1:nI  ,1:nJ+1,1:nK  ,y_,y_)=B0yFace_y_BLK(1:nI,1:nJ+1,1:nK,iBLK)
  B0face(1:nI  ,1:nJ+1,1:nK  ,z_,y_)=B0zFace_y_BLK(1:nI,1:nJ+1,1:nK,iBLK)
  B0face(1:nI  ,1:nJ  ,1:nK+1,x_,z_)=B0xFace_z_BLK(1:nI,1:nJ,1:nK+1,iBLK)
  B0face(1:nI  ,1:nJ  ,1:nK+1,y_,z_)=B0yFace_z_BLK(1:nI,1:nJ,1:nK+1,iBLK)
  B0face(1:nI  ,1:nJ  ,1:nK+1,z_,z_)=B0zFace_z_BLK(1:nI,1:nJ,1:nK+1,iBLK)

  if(UseHallResist)call impl_init_hall

  ! Initialize matrix to zero (to be safe)
  JAC=0.0

  ! Initialize reference flux and the cmax array
  do idim=1,ndim

     i1 = 1+kr(1,idim); j1= 1+kr(2,idim); k1= 1+kr(3,idim)
     i2 =nI+kr(1,idim); j2=nJ+kr(2,idim); k2=nK+kr(3,idim);

     call get_face_flux(qwk,B0face(i1:i2,j1:j2,k1:k2,:,idim),&
          nI,nJ,nK,iDim,iBLK,FluxLeft_FVD(i1:i2,j1:j2,k1:k2,:,iDim))

     call get_face_flux(qwk,B0face(1:nI,1:nJ,1:nK,:,iDim),&
          nI,nJ,nK,iDim,iBLK,FluxRight_FVD(:,:,:,:,iDim))

     ! Average w for each cell interface into weps
     i1 = 1-kr(1,idim); j1= 1-kr(2,idim); k1= 1-kr(3,idim)

     ! Calculate orthogonal cmax for each interface in advance
     call get_cmax_face(                            &
          0.5*(w_k( 1:i2, 1:j2, 1:k2,1:nw,implBLK)+ &
          w_k(i1:nI,j1:nJ,k1:nK,1:nw,implBLK)),     &
          B0face(1:i2,1:j2,1:k2,1:ndim,idim),       &
          i2,j2,k2,idim,iBlk,cmaxFace(1:i2,1:j2,1:k2,idim))

     ! cmax always occurs as -ImplCoeff*0.5/dx*cmax
     coeff = -ImplCoeff*0.5 
     cmaxFace(1:i2,1:j2,1:k2,idim)=coeff*cmaxFace(1:i2,1:j2,1:k2,idim)
  enddo

  ! Initialize divB and Qpowell arrays 
  if(divbsrc)call impl_divbsrc_init

  ! Set qS=S(qwk)
  if(implsource)call getsource(iBLK,qwk,qS)

  ! The w to be perturbed and jw is the index for the perturbed variable
  weps=qwk

  !DEBUG
  !write(*,*)'Initial weps=qwk'
  !write(*,'(a,8(f10.6))')'qwk(nK)   =', qwk(Itest,Jtest,Ktest,:)
  !write(*,'(a,8(f10.6))')'qwk(nK+1) =', qwk(Itest,Jtest,Ktest+1,:)
  !write(*,'(a,8(f10.6))')'weps(nK)  =',weps(Itest,Jtest,Ktest,:)
  !write(*,'(a,8(f10.6))')'weps(nK+1)=',weps(Itest,Jtest,Ktest+1,:)

  do jw=1,nw; 
     ! Remove perturbation from previous jw if there was a previous one
     if(jw>1)weps(:,:,:,jw-1)=qwk(:,:,:,jw-1)

     ! Perturb new jw variable
     coeff=qeps*wnrm(jw)
     weps(:,:,:,jw)=qwk(:,:,:,jw) + coeff

     do idim=1,ndim
        ! Index limits for faces and shifted centers
        i1 = 1+kr(1,idim); j1= 1+kr(2,idim); k1= 1+kr(3,idim)
        i2 =nI+kr(1,idim); j2=nJ+kr(2,idim); k2=nK+kr(3,idim);
        i3 =nI-kr(1,idim); j3=nJ-kr(2,idim); k3=nK-kr(3,idim);

        call get_face_flux(weps,B0face(i1:i2,j1:j2,k1:k2,:,idim),&
             nI,nJ,nK,iDim,iBLK,FluxEpsLeft_FV(i1:i2,j1:j2,k1:k2,:))

        call get_face_flux(weps,B0face(1:nI,1:nJ,1:nK,:,iDim),&
             nI,nJ,nK,iDim,iBLK,FluxEpsRight_FV)

        ! Calculate dfdw=(feps-f0)/eps for each iw variable and both
        ! left and right sides
        do iw=1,nw

           !call getflux(weps,B0face(i1:i2,j1:j2,k1:k2,:,idim),&
           !     nI,nJ,nK,iw,idim,implBLK,fepsLface(i1:i2,j1:j2,k1:k2))

           !call getflux(weps,B0face(1:nI,1:nJ,1:nK,:,idim),&
           !     nI,nJ,nK,iw,idim,implBLK,fepsRface(1:nI,1:nJ,1:nK))

           ! dfdw = F_iw(W + eps*W_jw) - F_iw(W)] / eps is multiplied by 
           ! -ImplCoeff/2/dx*wnrm(jw)/wnrm(iw) in all formulae
           coeff=-ImplCoeff*0.5/qeps/wnrm(iw) 

           dfdwLface(i1:i2,j1:j2,k1:k2)=coeff*&
                (FluxEpsLeft_FV(i1:i2,j1:j2,k1:k2,iw) &
                -FluxLeft_FVD(   i1:i2,j1:j2,k1:k2,iw,iDim)) 
           dfdwRface( 1:nI, 1:nJ, 1:nK)=coeff*&
                (FluxEpsRight_FV( 1:nI, 1:nJ, 1:nK, iW) &
                -FluxRight_FVD(   1:nI, 1:nJ, 1:nK, iW, iDim))

           if(oktest_me)write(*,'(a,i1,i2,6(f15.8))') &
                'iw,jw,f0L,fepsL,dfdwL,R:', &
                iw,bat2vac(jw),&
                FluxLeft_FVD(Itest,Jtest,Ktest,iw,idim),&
                FluxEpsLeft_FV(Itest,Jtest,Ktest,iW),&
                dfdwLface(Itest,Jtest,Ktest),&
                FluxRight_FVD(Itest,Jtest,Ktest,iw,idim),&
                FluxEpsRight_FV(Itest,Jtest,Ktest,iW),&
                dfdwRface(Itest,Jtest,Ktest)

           !DEBUG
           !if(idim==3.and.iw==4.and.jw==2)&
           !write(*,*)'BEFORE addcmax dfdw(iih)=',&
           !          dfdwLface(Itest,Jtest,Ktest-1)

           ! Add contribution of cmax to dfdwL and dfdwR
           if(iw==jw)then
              ! FxL_i-1/2 <-- (FxL + cmax)_i-1/2
              dfdwLface(i1:i2,j1:j2,k1:k2)=dfdwLface(i1:i2,j1:j2,k1:k2)&
                   +cmaxFace(i1:i2,j1:j2,k1:k2,idim)
              ! FxR_i+1/2 <-- (FxR - cmax)_i+1/2
              dfdwRface( 1:nI, 1:nJ, 1:nK)=dfdwRface( 1:nI, 1:nJ, 1:nK)&
                   -cmaxFace( 1:nI, 1:nJ, 1:nK,idim)
           endif

           ! Divide flux*area by volume
           dfdwLface(i1:i2,j1:j2,k1:k2) = dfdwLface(i1:i2,j1:j2,k1:k2) &
                *vInv_CB(1:nI, 1:nJ, 1:nK, iBlk)
           dfdwRface( 1:nI, 1:nJ, 1:nK) = dfdwRface( 1:nI, 1:nJ, 1:nK) &
                *vInv_CB(1:nI, 1:nJ, 1:nK, iBlk)

           !DEBUG
           !if(idim==3.and.iw==4.and.jw==2)&
           !write(*,*)'AFTER  addcmax dfdwL(iih)=',&
           !           dfdwLface(Itest,Jtest,Ktest-1)

           ! Contribution of fluxes to main diagonal (middle cell)
           ! dR_i/dW_i = 0.5/Dx*[ (dFxR/dW-cmax)_i-1/2 - (dFxL/dW+cmax)_i+1/2 ]

           JAC(iw,jw,:,:,:,1)=JAC(iw,jw,:,:,:,1) &
                +dfdwRface( 1:nI, 1:nJ, 1:nK)                      &
                -dfdwLface(i1:i2,j1:j2,k1:k2)


           ! Add Q*dB/dw to dfdwL and dfdwR for upper and lower diagonals
           ! These diagonals are non-zero for the inside interfaces only
           ! which corresponds to the range i1:nI,j1:nJ,k1:nK.
           if(divbsrc .and. &
                (iw>=RhoUx_.and.iw<=RhoUz_) .or. &
                (iW>=Bx_.and.iW<=Bz_) .or. &
                iw==E_)then
              if(UseCovariant .and. jw>=Bx_ .and. jw<=Bz_)then
                 ! The source terms are always multiplied by coeff
                 coeff=-ImplCoeff*0.5*wnrm(jw)/wnrm(iw)
                 ! Get the corresponding face area
                 select case(iDim)
                 case(x_)
                    FaceArea_F(i1:nI,j1:nJ,k1:nK) = &
                         FaceAreaI_DFB(jw-B_,i1:nI,j1:nJ,k1:nK,iBLK)
                 case(y_)
                    FaceArea_F(i1:nI,j1:nJ,k1:nK) = &
                         FaceAreaJ_DFB(jw-B_,i1:nI,j1:nJ,k1:nK,iBLK)
                 case(z_)
                    FaceArea_F(1:i3,1:j3,1:k3) = &
                         FaceAreaK_DFB(jw-B_,i1:nI,j1:nJ,k1:nK,iBlk)
                 end select

                 ! Relative to the right face flux Q is shifted to the left
                 dfdwLface(i1:nI,j1:nJ,k1:nK)=dfdwLface(i1:nI,j1:nJ,k1:nK)+ &
                      coeff*Qpowell(i1:nI,j1:nJ,k1:nK,iw) &
                      *FaceArea_F(i1:nI,j1:nJ,k1:nK) &
                      *vInv_CB(i1:nI,j1:nJ,k1:nK,iBlk)

                 dfdwRface(i1:nI,j1:nJ,k1:nK)=dfdwRface(i1:nI,j1:nJ,k1:nK)+ &
                      coeff*Qpowell( 1:i3, 1:j3, 1:k3,iw) &
                      *FaceArea_F(i1:nI,j1:nJ,k1:nK) &
                      *vInv_CB(1:i3,1:j3,1:k3,iBlk)

              elseif(jw==B_+idim)then
                 ! The source terms are always multiplied by coeff
                 coeff=-ImplCoeff*0.5/dxyz(idim)*wnrm(jw)/wnrm(iw)

                 ! Relative to the right face flux Q is shifted to the left
                 dfdwLface(i1:nI,j1:nJ,k1:nK)=dfdwLface(i1:nI,j1:nJ,k1:nK)+ &
                      coeff*Qpowell(i1:nI,j1:nJ,k1:nK,iw)

                 dfdwRface(i1:nI,j1:nJ,k1:nK)=dfdwRface(i1:nI,j1:nJ,k1:nK)+ &
                      coeff*Qpowell( 1:i3, 1:j3, 1:k3,iw)
              end if
           end if
           JAC(iw,jw,i1:nI,j1:nJ,k1:nK,2*idim  )=  dfdwLface(i1:nI,j1:nJ,k1:nK)
           JAC(iw,jw, 1:i3, 1:j3, 1:k3,2*idim+1)= -dfdwRface(i1:nI,j1:nJ,k1:nK)
        enddo ! iw
     enddo ! idim
     if(oktest_me)then
        write(*,*)'After fluxes jw=',jw,' stencil, row, JAC'
        do istencil=1,nstencil
           do qj=1,nw
              write(*,'(i1,a,i1,a,8(f9.5))')istencil,',',qj,':',&
                   JAC(bat2vac,bat2vac(qj),Itest,Jtest,Ktest,istencil)
           end do
        enddo
     endif

     !Derivatives of local source terms 
     if(implsource)then
        if(oktest_me)write(*,*)'Adding dS/dw'

        ! w2=S(qwk+eps*W_jw)
        call getsource(weps,qSeps)
        do iw=1,nw
           ! JAC(..1) += dS/dW_jw
           coeff=-ImplCoeff/qeps/wnrm(iw)
           JAC(iw,jw,:,:,:,1)=JAC(iw,jw,:,:,:,1)&
                +coeff*(qSeps(:,:,:,iw)-qS(:,:,:,iw))
        enddo
     endif
  enddo

  if(oktest_me)write(*,*)'After fluxes and sources:  JAC(...,1):', &
       JAC(1:nw,1:nw,Itest,Jtest,Ktest,1)

  ! Contribution of middle to Powell's source terms
  if(divbsrc)then
     ! JAC(...1) += d(Q/divB)/dW*divB
     call impl_divbsrc_middle

     if(oktest_me)then
        write(*,*)'After divb sources: row, JAC(...,1):'
        do qj=1,nw
           write(*,'(i1,a,8(f9.5))')qj,':',&
                JAC(bat2vac,bat2vac(qj),Itest,Jtest,Ktest,1)
        end do
     end if
  end if

  if(UseHallResist)call impl_hall_resist

  ! Multiply JAC by the implicit timestep dt
  if(time_accurate)then
     do k=1,nK; do j=1,nJ; do i=1,nI
        if(true_cell(i,j,k,iBLK))then
           JAC(:,:,i,j,k,:) = JAC(:,:,i,j,k,:)*dt
        else
           ! Set JAC = 0.0 inside body
           JAC(:,:,i,j,k,:) = 0.0
        end if
     end do; end do; end do
  else
     ! Local time stepping has time_BLK=0.0 inside the body
     do istencil=1,nstencil; do jw=1,nw; do iw=1,nw
        JAC(iw,jw,:,:,:,istencil)=JAC(iw,jw,:,:,:,istencil) &
             *time_BLK(1:nI,1:nJ,1:nK,iBLK)*implCFL
     end do; end do; end do
  endif

  if(oktest_me)then
     write(*,*)'After boundary correction and *dt: row, JAC(...,1):'
     do qj=1,nw
        write(*,'(i1,a,8(f9.5))')qj,':',&
             JAC(bat2vac,bat2vac(qj),Itest,Jtest,Ktest,1)
     end do
  end if

  ! Add unit matrix to main diagonal
  do iw=1,nw
     JAC(iw,iw,:,:,:,1)=JAC(iw,iw,:,:,:,1)+1.0
  end do

  if(oktest_me)then
     write(*,*)'After adding I: row, JAC(...,1):'
     do qj=1,nw
        write(*,'(i1,a,8(f9.5))')qj,':',&
             JAC(bat2vac,bat2vac(qj),Itest,Jtest,Ktest,1)
     end do
  end if

  ! Restore UseDivbSource
  if(divbsrc)UseDivbSource=UseDivbSource0

contains

  !===========================================================================
  subroutine impl_divbsrc_init

    ! Switch off UseDivbSource for addsource
    UseDivbSource0=UseDivbSource
    UseDivbSource=.false.

    ! Calculate div B for middle cell contribution to Powell's source terms
    if(UseCovariant)then
       do k=1,nK; do j=1,nJ; do i=1,nI
          divb(i,j,k) = 0.5*vInv_CB(i,j,k,iBlk)*( &
               sum(w_k(i+1,j,k,Bx_:Bz_,implBLK)*FaceAreaI_DFB(:,i+1,j,k,iBlk))&
               -sum(w_k(i-1,j,k,Bx_:Bz_,implBLK)*FaceAreaI_DFB(:,i,j,k,iBlk))+&
               sum(w_k(i,j+1,k,Bx_:Bz_,implBLK)*FaceAreaJ_DFB(:,i,j+1,k,iBlk))&
               -sum(w_k(i,j-1,k,Bx_:Bz_,implBLK)*FaceAreaJ_DFB(:,i,j,k,iBlk))+&
               sum(w_k(i,j,k+1,Bx_:Bz_,implBLK)*FaceAreaK_DFB(:,i,j,k+1,iBlk))&
               -sum(w_k(i,j,k-1,Bx_:Bz_,implBLK)*FaceAreaK_DFB(:,i,j,k,iBlk)))
       end do; end do; end do
    else
       divb=0.5*&
            ((w_k(2:nI+1,1:nJ,1:nK,Bx_,implBLK)           &
            -w_k(0:nI-1,1:nJ,1:nK,Bx_,implBLK))/dxyz(x_) &
            +(w_k(1:nI,2:nJ+1,1:nK,By_,implBLK)           &
            -w_k(1:nI,0:nJ-1,1:nK,By_,implBLK))/dxyz(y_) &
            +(w_k(1:nI,1:nJ,2:nK+1,Bz_,implBLK)           &
            -w_k(1:nI,1:nJ,0:nK-1,Bz_,implBLK))/dxyz(z_))
    end if

    ! Make sure that Qpowell is defined for all indexes
    Qpowell = 0.0

    ! Calculate the coefficients Q that multiply div B in Powell Source terms
    ! Q(rhoU)= B
    Qpowell(:,:,:,rhoUx_)=qwk(:,:,:,Bx_)
    Qpowell(:,:,:,rhoUy_)=qwk(:,:,:,By_)
    Qpowell(:,:,:,rhoUz_)=qwk(:,:,:,Bz_) 

    ! Q(B)   = U
    Qpowell(:,:,:,Bx_)=qwk(:,:,:,rhoUx_)/qwk(:,:,:,rho_) 
    Qpowell(:,:,:,By_)=qwk(:,:,:,rhoUy_)/qwk(:,:,:,rho_) 
    Qpowell(:,:,:,Bz_)=qwk(:,:,:,rhoUz_)/qwk(:,:,:,rho_) 

    ! Q(E)   = U.B
    Qpowell(:,:,:,E_)=(qwk(:,:,:,Bx_)*qwk(:,:,:,rhoUx_)&
         +qwk(:,:,:,By_)*qwk(:,:,:,rhoUy_)&
         +qwk(:,:,:,Bz_)*qwk(:,:,:,rhoUz_))&
         /qwk(:,:,:,rho_)

  end subroutine impl_divbsrc_init

  !===========================================================================
  subroutine impl_divbsrc_middle

    ! JAC(...1) += dQ/dW_i*divB

    ! Q(rhoU)= -divB*B
    ! dQ(rhoU)/dB = -divB
    JAC(rhoUx_,Bx_,:,:,:,1)=JAC(rhoUx_,Bx_,:,:,:,1)&
         +ImplCoeff*wnrm(Bx_)/wnrm(rhoUx_)*divb 
    JAC(rhoUy_,By_,:,:,:,1)=JAC(rhoUy_,By_,:,:,:,1)&
         +ImplCoeff*wnrm(By_)/wnrm(rhoUy_)*divb
    JAC(rhoUz_,Bz_,:,:,:,1)=JAC(rhoUz_,Bz_,:,:,:,1)&
         +ImplCoeff*wnrm(Bz_)/wnrm(rhoUz_)*divb

    ! Q(B)= -divB*rhoU/rho
    ! dQ(B)/drho = +divB*rhoU/rho**2
    JAC(Bx_,rho_,:,:,:,1)=JAC(Bx_,rho_,:,:,:,1) &
         -ImplCoeff*wnrm(rho_)/wnrm(Bx_)*divb*qwk(:,:,:,rhoUx_)/qwk(:,:,:,rho_)**2
    JAC(By_,rho_,:,:,:,1)=JAC(By_,rho_,:,:,:,1) &
         -ImplCoeff*wnrm(rho_)/wnrm(By_)*divb*qwk(:,:,:,rhoUy_)/qwk(:,:,:,rho_)**2
    JAC(Bz_,rho_,:,:,:,1)=JAC(Bz_,rho_,:,:,:,1) &
         -ImplCoeff*wnrm(rho_)/wnrm(Bz_)*divb*qwk(:,:,:,rhoUz_)/qwk(:,:,:,rho_)**2

    ! dQ(B)/drhoU= -divB/rho
    JAC(Bx_,rhoUx_,:,:,:,1)=JAC(Bx_,rhoUx_,:,:,:,1)&
         +ImplCoeff*wnrm(rhoUx_)/wnrm(Bx_)*divb/qwk(:,:,:,rho_) 
    JAC(By_,rhoUy_,:,:,:,1)=JAC(By_,rhoUy_,:,:,:,1)&
         +ImplCoeff*wnrm(rhoUy_)/wnrm(By_)*divb/qwk(:,:,:,rho_) 
    JAC(Bz_,rhoUz_,:,:,:,1)=JAC(Bz_,rhoUz_,:,:,:,1)&
         +ImplCoeff*wnrm(rhoUz_)/wnrm(Bz_)*divb/qwk(:,:,:,rho_) 

    ! Q(E)= -divB*rhoU.B/rho
    ! dQ(E)/drho = +divB*rhoU.B/rho**2
    JAC(E_,rho_,:,:,:,1)=JAC(E_,rho_,:,:,:,1)&
         -ImplCoeff*wnrm(rho_)/wnrm(E_)*divb*&
         (qwk(:,:,:,rhoUx_)*qwk(:,:,:,Bx_)&
         +qwk(:,:,:,rhoUy_)*qwk(:,:,:,By_)&
         +qwk(:,:,:,rhoUz_)*qwk(:,:,:,Bz_))&
         /qwk(:,:,:,rho_)**2

    ! dQ(E)/drhoU = -divB*B/rho
    JAC(E_,rhoUx_,:,:,:,1)=JAC(E_,rhoUx_,:,:,:,1) &
         +ImplCoeff*wnrm(rhoUx_)/wnrm(E_)*divb*qwk(:,:,:,Bx_)/qwk(:,:,:,rho_) 
    JAC(E_,rhoUy_,:,:,:,1)=JAC(E_,rhoUy_,:,:,:,1) &
         +ImplCoeff*wnrm(rhoUy_)/wnrm(E_)*divb*qwk(:,:,:,By_)/qwk(:,:,:,rho_) 
    JAC(E_,rhoUz_,:,:,:,1)=JAC(E_,rhoUz_,:,:,:,1) &
         +ImplCoeff*wnrm(rhoUz_)/wnrm(E_)*divb*qwk(:,:,:,Bz_)/qwk(:,:,:,rho_) 

    ! dQ(E)/dB = -divB*rhoU/rho
    JAC(E_,Bx_,:,:,:,1)=JAC(E_,Bx_,:,:,:,1) &
         +ImplCoeff*wnrm(Bx_)/wnrm(E_)*divb*qwk(:,:,:,rhoUx_)/qwk(:,:,:,rho_) 
    JAC(E_,By_,:,:,:,1)=JAC(E_,By_,:,:,:,1) &
         +ImplCoeff*wnrm(By_)/wnrm(E_)*divb*qwk(:,:,:,rhoUy_)/qwk(:,:,:,rho_) 
    JAC(E_,Bz_,:,:,:,1)=JAC(E_,Bz_,:,:,:,1) &
         +ImplCoeff*wnrm(Bz_)/wnrm(E_)*divb*qwk(:,:,:,rhoUz_)/qwk(:,:,:,rho_) 

  end subroutine impl_divbsrc_middle

  !===========================================================================
  subroutine impl_init_hall

    use ModHallResist, ONLY: HallJ_CD, IonMassPerCharge_G, &
         BxPerN_G, ByPerN_G, BzPerN_G, set_ion_mass_per_charge

    real :: InvDx2, InvDy2, InvDz2, InvN_G(0:nI+1,0:nJ+1,0:nK+1)
    ! Calculate cell centered currents to be used by getflux

    InvDx2 = 0.5/Dxyz(x_); InvDy2 = 0.5/Dxyz(y_); InvDz2 = 0.5/Dxyz(z_)

    do k=1,nK; do j=1,nJ; do i=1,nI
       HallJ_CD(i,j,k,x_) = &
            +InvDy2*(w_k(i,j+1,k,Bz_,implBLK)-w_k(i,j-1,k,Bz_,implBLK)) &
            -InvDz2*(w_k(i,j,k+1,By_,implBLK)-w_k(i,j,k-1,By_,implBLK))
    end do; end do; end do

    do k=1,nK; do j=1,nJ; do i=1,nI
       HallJ_CD(i,j,k,y_) = &
            +InvDz2*(w_k(i,j,k+1,Bx_,implBLK)-w_k(i,j,k-1,Bx_,implBLK)) &
            -InvDx2*(w_k(i+1,j,k,Bz_,implBLK)-w_k(i-1,j,k,Bz_,implBLK))
    end do; end do; end do

    do k=1,nK; do j=1,nJ; do i=1,nI
       HallJ_CD(i,j,k,z_) = &
            +InvDx2*(w_k(i+1,j,k,By_,implBLK)-w_k(i-1,j,k,By_,implBLK)) &
            -InvDy2*(w_k(i,j+1,k,Bx_,implBLK)-w_k(i,j-1,k,Bx_,implBLK))
    end do; end do; end do

    call set_ion_mass_per_charge(impl2iBLK(implBlk))

    do k=1,nK; do j=1,nJ; do i=1,nI
       HallJ_CD(i,j,k,:) = IonMassPerCharge_G(i,j,k) &
            *hall_factor(0,i,j,k,iBlk)*HallJ_CD(i,j,k,:)
    end do; end do; end do

    InvN_G = IonMassPerCharge_G / w_k(:,:,:,Rho_,implBLK)

    BxPerN_G = w_k(:,:,:,Bx_,implBLK)*InvN_G 
    ByPerN_G = w_k(:,:,:,By_,implBLK)*InvN_G 
    BzPerN_G = w_k(:,:,:,Bz_,implBLK)*InvN_G

  end subroutine impl_init_hall
  !===========================================================================
  subroutine impl_hall_resist

    use ModHallResist, ONLY: BxPerN_G, ByPerN_G, BzPerN_G
    !real :: ResistDiag should be Eta0Resist_ND from calc_resistive_flux

    real :: Coeff
    integer:: iVar

    ! For diffusion term
    ! R(Bi) = d^2(Bi)/dx^2 + d^2(Bi)/dy^2 + d^2(Bi)/dz^2 
    ! dR(Bx)/dBx, dR(By)/dBy, dR(Bz)/dBz 
    
    !do iDim = 1, nDim
    !   Coeff= - ImplCoeff*ResistDiag/Dxyz(iDim)**2
    !   do k=1,nK; do j=1,nJ; do i=1,nI
    !      do iVar=Bx_, Bz_
    !         JAC(iVar,iVar,i,j,k,1)= &
    !              JAC(iVar,iVar,i,j,k,1)         - 2.0*Coeff
    !         JAC(iVar,iVar,i,j,k,2*nDim)= &
    !              JAC(iVar,iVar,i,j,k,2*nDim)    + Coeff
    !         JAC(iVar,iVar,i,j,k,2*nDim+1)= & 
    !              JAC(iVar,iVar,i,j,k,2*nDim+1)  + Coeff
    !      end do
    !   end do; end do; end do
    !end do



    ! For Hall term
    ! the signs should be reversed and the coeff should have a minus sign

    ! dR(Bx)/dBy
    Coeff = ImplCoeff*wnrm(By_)/wnrm(Bx_)/Dxyz(z_)**2
    ! Main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       JAC(Bx_,By_,i,j,k,1)= JAC(Bx_,By_,i,j,k,1) &
            + Coeff*(BzPerN_G(i,j,k-1)+BzPerN_G(i,j,k+1))
    end do; end do; end do
    !J+1
    do k=1,nK-1; do j=1,nJ; do i=1,nI
       JAC(Bx_,By_,i,j,k,7)=JAC(Bx_,By_,i,j,k,7) - Coeff*BzPerN_G(i,j,k+1)
    end do; end do; end do
    !J-1
    do k=2,nK; do j=1,nJ; do i=1,nI
       JAC(Bx_,By_,i,j,k,6)=JAC(Bx_,By_,i,j,k,6) - Coeff*BzPerN_G(i,j,k-1)
    end do; end do; end do

    ! dR(Bx)/dBz
    Coeff = ImplCoeff*wnrm(Bz_)/wnrm(Bx_)/Dxyz(y_)**2
    ! Main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       JAC(Bx_,Bz_,i,j,k,1)= JAC(Bx_,Bz_,i,j,k,1) &
            - Coeff*(ByPerN_G(i,j-1,k)+ByPerN_G(i,j+1,k))
    end do; end do; end do
    !J+1
    do k=1,nK; do j=1,nJ-1; do i=1,nI
       JAC(Bx_,Bz_,i,j,k,5)= JAC(Bx_,Bz_,i,j,k,5) + Coeff*ByPerN_G(i,j+1,k)
    end do; end do; end do
    !J-1
    do k=1,nK; do j=2,nJ; do i=1,nI
       JAC(Bx_,Bz_,i,j,k,4)= JAC(Bx_,Bz_,i,j,k,4) + Coeff*ByPerN_G(i,j-1,k)
    end do; end do; end do

    ! dR(By)/dBz
    Coeff = ImplCoeff*wnrm(Bz_)/wnrm(By_)/Dxyz(x_)**2
    ! Main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       JAC(By_,Bz_,i,j,k,1)= JAC(By_,Bz_,i,j,k,1) &
            + Coeff*(BxPerN_G(i-1,j,k)+BxPerN_G(i+1,j,k))
    end do; end do; end do
    !I+1
    do k=1,nK; do j=1,nJ; do i=1,nI-1
       JAC(By_,Bz_,i,j,k,3)= JAC(By_,Bz_,i,j,k,3) - Coeff*BxPerN_G(i+1,j,k)
    end do; end do; end do
    !I-1
    do k=1,nK; do j=1,nJ; do i=2,nI
       JAC(By_,Bz_,i,j,k,2)= JAC(By_,Bz_,i,j,k,2) - Coeff*BxPerN_G(i-1,j,k)
    end do; end do; end do

    ! dR(By)/dBx
    Coeff = ImplCoeff*wnrm(Bx_)/wnrm(By_)/Dxyz(z_)**2
    ! Main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       JAC(By_,Bx_,i,j,k,1)= JAC(By_,Bx_,i,j,k,1) &
            - Coeff*(BzPerN_G(i,j,k-1)+BzPerN_G(i,j,k+1))
    end do; end do; end do
    !K+1
    do k=1,nK-1; do j=1,nJ; do i=1,nI
       JAC(By_,Bx_,i,j,k,7)=JAC(By_,Bx_,i,j,k,7) + Coeff*BzPerN_G(i,j,k+1)
    end do; end do; end do
    !K-1
    do k=2,nK; do j=1,nJ; do i=1,nI
       JAC(By_,Bx_,i,j,k,6)=JAC(By_,Bx_,i,j,k,6) + Coeff*BzPerN_G(i,j,k-1)
    end do; end do; end do

    ! dR(Bz)/dBx
    Coeff = ImplCoeff*wnrm(Bx_)/wnrm(Bz_)/Dxyz(y_)**2
    ! Main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       JAC(Bz_,Bx_,i,j,k,1)= JAC(Bz_,Bx_,i,j,k,1) &
            + Coeff*(ByPerN_G(i,j-1,k)+ByPerN_G(i,j+1,k))
    end do; end do; end do
    !J+1
    do k=1,nK; do j=1,nJ-1; do i=1,nI
       JAC(Bz_,Bx_,i,j,k,5)=JAC(Bz_,Bx_,i,j,k,5) - Coeff*ByPerN_G(i,j+1,k)
    end do; end do; end do
    !J-1
    do k=1,nK; do j=2,nJ; do i=1,nI
       JAC(Bz_,Bx_,i,j,k,4)=JAC(Bz_,Bx_,i,j,k,4) - Coeff*ByPerN_G(i,j-1,k)
    end do; end do; end do

    ! dR(Bz)/dBy
    Coeff = ImplCoeff*wnrm(By_)/wnrm(Bz_)/Dxyz(x_)**2
    ! Main diagonal
    do k=1,nK; do j=1,nJ; do i=1,nI
       JAC(Bz_,By_,i,j,k,1)= JAC(Bz_,By_,i,j,k,1) &
            - Coeff*(BxPerN_G(i-1,j,k)+BxPerN_G(i+1,j,k))
    end do; end do; end do
    !I+1
    do k=1,nK; do j=1,nJ; do i=1,nI-1
       JAC(Bz_,By_,i,j,k,3)= JAC(Bz_,By_,i,j,k,3) + Coeff*BxPerN_G(i+1,j,k)
    end do; end do; end do
    !I-1
    do k=1,nK; do j=1,nJ; do i=2,nI
       JAC(Bz_,By_,i,j,k,2)= JAC(Bz_,By_,i,j,k,2) + Coeff*BxPerN_G(i-1,j,k)
    end do; end do; end do

  end subroutine impl_hall_resist

end subroutine impl_jacobian
