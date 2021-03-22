!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModUpdateStateGpu

  use ModMain, ONLY: iStage, Cfl
  use ModAdvance
  use BATL_lib, ONLY: nI, nJ, nK, CellVolume_GB
  use ModEnergy, ONLY: calc_energy_or_pressure
  use ModMultiFluid, ONLY: nFluid, IonLast_, &
       iRho, iRhoUx, iRhoUy, iRhoUz, iP, select_fluid
  use ModPhysics,    ONLY: GammaMinus1_I
  
  implicit none

contains
  !============================================================================
  subroutine update_state_gpu(iBlock)
    !$acc routine vector
    integer, intent(in):: iBlock

    integer:: iVar, iFluid, i, j, k, iGang
#ifdef OPENACC
    !--------------------------------------------------------------------------
      iGang = iBlock
#else
      iGang = 1
#endif

      !$acc loop vector collapse(3)
      do k = 1,nK; do j = 1,nJ; do i = 1,nI
         StateOld_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock)
         EnergyOld_CBI(i,j,k,iBlock,1) = Energy_GBI(i,j,k,iBlock,1)

         State_VGB(:,i,j,k,iBlock) = StateOld_VGB(:,i,j,k,iBlock) & 
              + Cfl*time_BLK(i,j,k,iBlock)* &
              (Source_VCI(1:nVar,i,j,k,iGang) + &
              ( Flux_VXI(1:nVar,i,j,k,iGang) - Flux_VXI(1:nVar,i+1,j,k,iGang)  &
              + Flux_VYI(1:nVar,i,j,k,iGang) - Flux_VYI(1:nVar,i,j+1,k,iGang)  &
              + Flux_VZI(1:nVar,i,j,k,iGang) - Flux_VZI(1:nVar,i,j,k+1,iGang)  ) &
              /CellVolume_GB(i,j,k,iBlock) &
              )

         Energy_GBI(i,j,k,iBlock,1) = EnergyOld_CBI(i,j,k,iBlock,1) &
              + Cfl*time_BLK(i,j,k,iBlock)* &
              (Source_VCI(nVar+1,i,j,k,iGang) + &
              ( Flux_VXI(nVar+1,i,j,k,iGang) - Flux_VXI(nVar+1,i+1,j,k,iGang)  &
              + Flux_VYI(nVar+1,i,j,k,iGang) - Flux_VYI(nVar+1,i,j+1,k,iGang)  &
              + Flux_VZI(nVar+1,i,j,k,iGang) - Flux_VZI(nVar+1,i,j,k+1,iGang)  ) &
              /CellVolume_GB(i,j,k,iBlock) &
              )

         ! Calculate pressure from energy
         State_VGB(p_,i,j,k,iBlock) = &
              GammaMinus1_I(1)*( Energy_GBI(i,j,k,iBlock,1) - &
              0.5*( &
              ( State_VGB(RhoUx_,i,j,k,iBlock)**2 &
              + State_VGB(RhoUy_,i,j,k,iBlock)**2 &
              + State_VGB(RhoUz_,i,j,k,iBlock)**2 &
              )/State_VGB(Rho_,i,j,k,iBlock)      &
              + State_VGB(Bx_,i,j,k,iBlock)**2    &
              + State_VGB(By_,i,j,k,iBlock)**2    &
              + State_VGB(Bz_,i,j,k,iBlock)**2    &
              )          )

      enddo; enddo; enddo
    
  end subroutine update_state_gpu
  !============================================================================

end module ModUpdateStateGpu
!==============================================================================
