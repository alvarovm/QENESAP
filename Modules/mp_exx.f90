!
! Copyright (C) 2013 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
MODULE mp_exx
  !----------------------------------------------------------------------------
  !
  USE mp, ONLY : mp_barrier, mp_bcast, mp_size, mp_rank, mp_comm_split
  USE parallel_include
  !
  IMPLICIT NONE 
  SAVE
  !
  ! ... Band groups (processors within a pool of bands)
  ! ... Subdivision of pool group, used for parallelization over bands
  !
  INTEGER :: negrp       = 1  ! number of band groups
  INTEGER :: nproc_egrp  = 1  ! number of processors within a band group
  INTEGER :: me_egrp     = 0  ! index of the processor within a band group
  INTEGER :: root_egrp   = 0  ! index of the root processor within a band group
  INTEGER :: my_egrp_id  = 0  ! index of my band group
  INTEGER :: inter_egrp_comm  = 0  ! inter band group communicator
  INTEGER :: intra_egrp_comm  = 0  ! intra band group communicator  
  !<<<
  INTEGER :: max_pairs ! maximum pairs per band group
  INTEGER, ALLOCATABLE :: egrp_pairs(:,:,:) ! pairs for each band group
  INTEGER, ALLOCATABLE :: band_roots(:) ! root for each band
  LOGICAL, ALLOCATABLE :: contributed_bands(:) ! bands for which the bgroup has a pair
  !>>>
  INTEGER :: iexx_start = 0              ! starting band index used in bgrp parallelization
  INTEGER :: iexx_end = 0                ! ending band index used in bgrp parallelization
  LOGICAL :: tegrp       = .FALSE. ! logical flag. .TRUE. when negrp > 1
  !
  ! ... "task" groups (for band parallelization of FFT)
  !
  INTEGER :: ntask_groups = 1  ! number of proc. in an orbital "task group"
  !
CONTAINS
  !
  !----------------------------------------------------------------------------
  SUBROUTINE mp_start_exx( nband_, ntg_, parent_comm )
    !---------------------------------------------------------------------------
    !
    ! ... Divide processors (of the "parent_comm" group) into nband_ pools
    ! ... Requires: nband_, read from command line
    ! ...           parent_comm, typically processors of a k-point pool
    ! ...           (intra_pool_comm)
    !
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN) :: nband_, parent_comm
    INTEGER, INTENT(IN), OPTIONAL :: ntg_
    !
    INTEGER :: parent_nproc = 1, parent_mype = 0
    !
#if defined (__MPI)
    !
    parent_nproc = mp_size( parent_comm )
    parent_mype  = mp_rank( parent_comm )
    !
    ! ... nband_ must have been previously read from command line argument
    ! ... by a call to routine get_command_line
    !
    negrp = nband_
    !
    IF ( negrp < 1 .OR. negrp > parent_nproc ) CALL errore( 'mp_start_bands',&
                          'invalid number of band groups, out of range', 1 )
    IF ( MOD( parent_nproc, negrp ) /= 0 ) CALL errore( 'mp_start_bands', &
        'n. of band groups  must be divisor of parent_nproc', 1 )
    !
    ! set the logical flag tegrp 
    !
    tegrp = ( negrp > 1 )
    ! 
    ! ... Set number of processors per band group
    !
    nproc_egrp = parent_nproc / negrp
    !
    ! ... set index of band group for this processor   ( 0 : negrp - 1 )
    !
    my_egrp_id = parent_mype / nproc_egrp
    !
    ! ... set index of processor within the image ( 0 : nproc_image - 1 )
    !
    me_egrp    = MOD( parent_mype, nproc_egrp )
    !
    CALL mp_barrier( parent_comm )
    !
    ! ... the intra_egrp_comm communicator is created
    !
    CALL mp_comm_split( parent_comm, my_egrp_id, parent_mype, intra_egrp_comm )
    !
    CALL mp_barrier( parent_comm )
    !
    ! ... the inter_egrp_comm communicator is created                     
    !     
    CALL mp_comm_split( parent_comm, me_egrp, parent_mype, inter_egrp_comm )  
    !
    IF ( PRESENT(ntg_) ) THEN
       ntask_groups = ntg_
    END IF
    !
#endif
    RETURN
    !
  END SUBROUTINE mp_start_exx
  !<<<
  !
  SUBROUTINE init_index_over_band(comm,nbnd)
    !
    USE io_global, ONLY : stdout
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: comm, nbnd
    
    INTEGER :: npe, myrank, rest, k
    INTEGER :: i, j, ipair, iegrp, root
    INTEGER :: ibnd, npairs
    INTEGER :: n_underloaded ! number of band groups that are under max load
    INTEGER :: pair_bands(nbnd,nbnd)
    INTEGER, ALLOCATABLE :: all_start(:)
    INTEGER, ALLOCATABLE :: all_end(:)
    
    !IF (ALLOCATED(all_start)) THEN
    !   DEALLOCATE( all_start, all_end )
    !END IF
    ALLOCATE( all_start(negrp) )
    ALLOCATE( all_end(negrp) )
    
    myrank = mp_rank(comm)
    npe = mp_size(comm)

    rest = mod(nbnd, npe)
    k = int(nbnd/npe)
    
    IF ( k >= 1 ) THEN
       IF ( rest > myrank ) THEN
          iexx_start = (myrank)*k + (myrank+1)
          iexx_end = (myrank+1)*k + (myrank+1)
       ELSE
          iexx_start = (myrank)*k + rest + 1
          iexx_end = (myrank+1)*k + rest
       END IF
    ELSE
       iexx_start = 1
       iexx_end = nbnd
    END IF

    !determine iexx_start and iexx_end for all of the other bands
    DO i=1, negrp
       IF ( k >= 1 ) THEN
          IF ( rest > i-1 ) THEN
             all_start(i) = (i-1)*k + i
             all_end(i) = i*k + i
          ELSE
             all_start(i) = (i-1)*k + rest + 1
             all_end(i) = i*k + rest
          END IF
       ELSE
          iexx_start = 1
          iexx_end = nbnd
       END IF
    END DO

    !assign the pairs for each band group
    max_pairs = CEILING(REAL(nbnd*nbnd)/REAL(negrp))
    IF (.not.allocated(egrp_pairs)) THEN
       ALLOCATE(egrp_pairs(2,max_pairs,negrp))
       ALLOCATE(band_roots(nbnd))
       ALLOCATE(contributed_bands(nbnd))
    END IF
    n_underloaded = MODULO(nbnd*nbnd-(max_pairs-1)*negrp,negrp)
    
    pair_bands = 0
    egrp_pairs = 0
    DO iegrp=1, negrp
       j = all_start(iegrp) !SHOULD CHANGE TO SOMETHING ELSE, IN CASE negrp > nbnd
       
       npairs = max_pairs
       IF (iegrp.le.n_underloaded) npairs = npairs - 1
       DO ipair=1, npairs
          !get the first value of i for which the (i,j) pair has not been assigned yet
          i = 1
          DO WHILE (i.le.nbnd.and.pair_bands(i,j).gt.0)
             i = i + 1
          END DO
          IF (i.le.nbnd) THEN
             pair_bands(i,j) = iegrp
          END IF
          egrp_pairs(1,ipair,iegrp) = i
          egrp_pairs(2,ipair,iegrp) = j
          
          j = j + 1
          IF (j.gt.nbnd) j = 1
       END DO

    END DO

    !create a list of the roots for each band
    root = 0
    DO i=1, nbnd
       band_roots(i) = root
       IF (MODULO(i,k).eq.0) root = root + 1
    END DO

    !determine the bands for which this band group will calculate a pair
    contributed_bands = .FALSE.
    DO ipair=1, max_pairs
       contributed_bands(egrp_pairs(1,ipair,myrank+1)) = .TRUE.
    END DO

  END SUBROUTINE init_index_over_band
  !>>>
  !
  SUBROUTINE set_egrp_indices(nbnd, ib_start, ib_end)
    !
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: nbnd
    INTEGER, INTENT(OUT) :: ib_start, ib_end

    INTEGER :: rest, nbnd_per_bgrp

    rest = mod ( nbnd, negrp )
    nbnd_per_bgrp = int( nbnd / negrp ) 

    IF (rest > my_egrp_id) THEN 
       ib_start =  my_egrp_id    * (nbnd_per_bgrp+1) + 1
       ib_end   = (my_egrp_id+1) * (nbnd_per_bgrp+1) 
    ELSE
       ib_start =  my_egrp_id    * nbnd_per_bgrp + rest + 1
       ib_end   = (my_egrp_id+1) * nbnd_per_bgrp + rest 
    ENDIF

  END SUBROUTINE set_egrp_indices

  INTEGER FUNCTION egrp_start(nbnd)
    !
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: nbnd

    INTEGER :: rest, nbnd_per_bgrp

    rest = mod ( nbnd, negrp )
    nbnd_per_bgrp = int( nbnd / negrp ) 

    IF (rest > my_egrp_id) THEN 
       egrp_start =  my_egrp_id    * (nbnd_per_bgrp+1) + 1
    ELSE
       egrp_start =  my_egrp_id    * nbnd_per_bgrp + rest + 1
    ENDIF

  END FUNCTION egrp_start

  INTEGER FUNCTION egrp_end(nbnd)
    !
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: nbnd

    INTEGER :: rest, nbnd_per_bgrp

    rest = mod ( nbnd, negrp )
    nbnd_per_bgrp = int( nbnd / negrp ) 

    IF (rest > my_egrp_id) THEN 
       egrp_end   = (my_egrp_id+1) * (nbnd_per_bgrp+1) 
    ELSE
       egrp_end   = (my_egrp_id+1) * nbnd_per_bgrp + rest 
    ENDIF

  END FUNCTION egrp_end

END MODULE mp_exx
!
!     
