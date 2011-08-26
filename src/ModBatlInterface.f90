module ModBatlInterface

  implicit none

  logical, public :: UseBatlTest = .false.

contains
  !===========================================================================
  subroutine set_batsrus_grid

    use BATL_lib, ONLY: nNodeUsed, nBlock, MaxBlock, Unused_B, Unused_BP, &
         iProc, iComm, iNodeMorton_I, iTree_IA, Block_, Proc_

    use ModAmr, ONLY: UnusedBlock_BP
    use ModParallel, ONLY: iBlock_A, iProc_A

    use ModMain, ONLY: nBlockAll, nBlockBats => nBlock, nBlockMax, UnusedBlk

    use ModGeometry, ONLY: dx_BLK, MinDxValue, MaxDxValue

    use ModAdvance, ONLY: iTypeAdvance_B, iTypeAdvance_BP, &
         SkippedBlock_, ExplBlock_
    use ModMpi

    integer:: iBlock, iError, iMorton, iNode
    real   :: DxMin, DxMax
    !-------------------------------------------------------------------------

    nBlockAll  = nNodeUsed
    nBlockBats = nBlock
    call MPI_ALLREDUCE(nBlock, nBlockMax, 1, MPI_INTEGER, MPI_MAX, &
         iComm, iError)

    UnusedBlk      = Unused_B
    UnusedBlock_BP = Unused_BP

    do iMorton = 1, nNodeUsed
       iNode = iNodeMorton_I(iMorton)
       iBlock_A(iMorton) = iTree_IA(Block_,iNode)
       iProc_A(iMorton) = iTree_IA(Proc_,iNode)
    end do

    where(Unused_BP)
       iTypeAdvance_BP = SkippedBlock_
    elsewhere
       iTypeAdvance_BP = ExplBlock_
    end where
    iTypeAdvance_B = iTypeAdvance_BP(:,iProc)

    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE
       call set_batsrus_block(iBlock)
    end do

    DxMin = minval(dx_BLK, MASK=(.not.Unused_B))
    DxMax = maxval(dx_BLK, MASK=(.not.Unused_B))
    call MPI_allreduce(DxMin, minDXvalue,1,MPI_REAL,MPI_MIN,iComm,iError)
    call MPI_allreduce(DxMax, maxDXvalue,1,MPI_REAL,MPI_MAX,iComm,iError)

  end subroutine set_batsrus_grid
  !===========================================================================
  subroutine set_batsrus_block(iBlock)

    use ModMain, ONLY: iNewGrid, iNewDecomposition

    use BATL_lib, ONLY: iProc, nDim, nI, nJ, nK, &
         CellSize_DB, CoordMin_DB, &
         iNode_B, iNodeNei_IIIB, DiLevelNei_IIIB, &
         iTree_IA, Block_, Proc_, Unset_, &
         IsRzGeometry, CellFace_DFB, IsNewDecomposition, IsNewTree
    use ModGeometry, ONLY: dx_BLK, dy_BLK, dz_BLK, XyzStart_BLK, &
         FaceAreaI_DFB, FaceAreaJ_DFB, FaceAreaK_DFB, &
         FaceArea2MinI_B, FaceArea2MinJ_B, FaceArea2MinK_B

    use ModParallel, ONLY: BLKneighborLEV,  neiLEV, neiBLK, neiPE, &
         neiLeast, neiLwest, neiLsouth, neiLnorth, neiLbot, neiLtop, &
         neiBeast, neiBwest, neiBsouth, neiBnorth, neiBbot, neiBtop, &
         neiPeast, neiPwest, neiPsouth, neiPnorth, neiPbot, neiPtop

    integer, intent(in):: iBlock

    ! Convert from BATL to BATSRUS ordering of subfaces. 
    integer, parameter:: iOrder_I(4) = (/1,3,2,4/)
    integer:: iNodeNei, iNodeNei_I(4)
    !-------------------------------------------------------------------------
    BLKneighborLEV(:,:,:,iBlock) = DiLevelNei_IIIB(:,:,:,iBlock)

    neiLeast(iBlock)  = BLKneighborLEV(-1,0,0,iBlock)
    neiLwest(iBlock)  = BLKneighborLEV(+1,0,0,iBlock)
    neiLsouth(iBlock) = BLKneighborLEV(0,-1,0,iBlock)
    neiLnorth(iBlock) = BLKneighborLEV(0,+1,0,iBlock)
    neiLbot(iBlock)   = BLKneighborLEV(0,0,-1,iBlock)
    neiLtop(iBlock)   = BLKneighborLEV(0,0,+1,iBlock)

    neiLEV(1,iBlock)  = neiLeast(iBlock)
    neiLEV(2,iBlock)  = neiLwest(iBlock)
    neiLEV(3,iBlock)  = neiLsouth(iBlock)
    neiLEV(4,iBlock)  = neiLnorth(iBlock)
    neiLEV(5,iBlock)  = neiLbot(iBlock)
    neiLEV(6,iBlock)  = neiLtop(iBlock)

    ! neiBeast ... neiPbot are used in 
    ! ModFaceValue::correct_monotone_restrict and
    ! ModConserveFlux::apply_cons_flux

    select case(DiLevelNei_IIIB(-1,0,0,iBlock))
    case(Unset_)
       neiBeast(:,iBlock)  = Unset_
       neiPeast(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(0,1:2,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBeast(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPeast(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(0,1,1,iBlock)
       neiBeast(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPeast(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(+1,0,0,iBlock))
    case(Unset_)
       neiBwest(:,iBlock)  = Unset_
       neiPwest(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(3,1:2,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBwest(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPwest(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(3,1,1,iBlock)
       neiBwest(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPwest(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,-1,0,iBlock))
    case(Unset_)
       neiBsouth(:,iBlock)  = Unset_
       neiPsouth(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,0,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBsouth(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPsouth(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,0,1,iBlock)
       neiBsouth(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPsouth(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,+1,0,iBlock))
    case(Unset_)
       neiBnorth(:,iBlock)  = Unset_
       neiPnorth(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,3,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBnorth(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPnorth(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,3,1,iBlock)
       neiBnorth(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPnorth(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,0,-1,iBlock))
    case(Unset_ )
       neiBbot(:,iBlock)  = Unset_
       neiPbot(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,1:2,0,iBlock),.true.)
       neiBbot(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPbot(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,1,0,iBlock)
       neiBbot(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPbot(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,0,+1,iBlock))
    case(Unset_)
       neiBtop(:,iBlock)  = Unset_
       neiPtop(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,1:2,3,iBlock),.true.)
       neiBtop(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPtop(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,1,3,iBlock)
       neiBtop(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPtop(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    ! neiBLK and neiPE are used in ray_pass, constrain_B, ModPartSteady
    neiBLK(:,1,iBlock) = neiBeast(:,iBlock)
    neiBLK(:,2,iBlock) = neiBwest(:,iBlock)
    neiBLK(:,3,iBlock) = neiBsouth(:,iBlock)
    neiBLK(:,4,iBlock) = neiBnorth(:,iBlock)
    neiBLK(:,5,iBlock) = neiBbot(:,iBlock)
    neiBLK(:,6,iBlock) = neiBtop(:,iBlock)

    neiPE(:,1,iBlock) = neiPeast(:,iBlock)
    neiPE(:,2,iBlock) = neiPwest(:,iBlock)
    neiPE(:,3,iBlock) = neiPsouth(:,iBlock)
    neiPE(:,4,iBlock) = neiPnorth(:,iBlock)
    neiPE(:,5,iBlock) = neiPbot(:,iBlock)
    neiPE(:,6,iBlock) = neiPtop(:,iBlock)

    XyzStart_BLK(:,iBlock) = CoordMin_DB(:,iBlock) + 0.5*CellSize_DB(:,iBlock)

    dx_BLK(iBlock) = CellSize_DB(1,iBlock)
    dy_BLK(iBlock) = CellSize_DB(2,iBlock)
    dz_BLK(iBlock) = CellSize_DB(3,iBlock)

    call fix_block_geometry(iBlock)

    if(IsRzGeometry)then
       ! This is like Cartesian except for the areas in R (=x) and Z (=y)
       FaceAreaI_DFB(:,:,:,:,iBlock) = 0.0
       FaceAreaJ_DFB(:,:,:,:,iBlock) = 0.0
       FaceAreaK_DFB(:,:,:,:,iBlock) = 0.0
       FaceAreaI_DFB(1,:,:,:,iBlock) = CellFace_DFB(1,:,1:nJ,1:nK,iBlock)
       FaceAreaJ_DFB(2,:,:,:,iBlock) = CellFace_DFB(2,1:nI,:,1:nK,iBlock)
       FaceArea2MinI_B(iBlock) = 1e-30
       FaceArea2MinJ_B(iBlock) = 1e-30
       FaceArea2MinK_B(iBlock) = 1e-30
    end if

    ! Tell if the grid and/or the tree has changed
    if(IsNewDecomposition) iNewDecomposition = mod(iNewDecomposition+1,10000)
    if(IsNewTree) iNewGrid = mod( iNewGrid+1, 10000)
    ! If regrid_batl is not called in each time step, we say that the
    ! grid/tree is not changed from the view of BATL
    IsNewDecomposition = .false.
    IsNewTree          = .false.

  end subroutine set_batsrus_block
  !============================================================================
  subroutine set_batsrus_state

    ! Here we should fix B0 and other things

    use BATL_lib, ONLY: nBlock, iAmrChange_B, AmrMoved_, Unused_B,&
         restrict_amr_criteria
    use ModEnergy, ONLY: calc_energy_cell
    
    integer:: iBlock
    !-------------------------------------------------------------------------

     do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE
              
       ! If nothing happened to the block, no need to do anything
       if(iAmrChange_B(iBlock) < AmrMoved_) CYCLE
       
       ! Update all kinds of extra block variables
       call calc_other_soln_vars(iBlock)
       call fix_soln_block(iBlock)
       call calc_energy_cell(iBlock)
       call restrict_amr_criteria(iBlock)
    end do

  end subroutine set_batsrus_state
  !============================================================================

end module ModBatlInterface
